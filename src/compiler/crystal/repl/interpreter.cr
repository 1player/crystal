require "./repl"
require "../../../crystal/ffi"
require "colorize"

class Crystal::Repl::Interpreter
  record CallFrame,
    # The CompiledDef related to this call frame
    compiled_def : CompiledDef,
    # Instructions for this frame
    instructions : Array(UInt8),
    # Nodes to related instructions indexes back to ASTNodes (mainly for location purposes)
    nodes : Hash(Int32, ASTNode),
    # The pointer to the current instruction for this call frame.
    # This value changes as the program goes, and when a call is made
    # this value is useful to know where we need to continue after
    # the call returns.
    ip : Pointer(UInt8),
    # What's the frame's stack.
    # This value changes as the program goes, and when a call is made
    # this value is useful to know what values in the stack we need
    # to have when the call returns.
    stack : Pointer(UInt8),
    # What's the frame's stack bottom. After this position come the
    # def's local variables.
    stack_bottom : Pointer(UInt8),
    # The index of the frame that called a block.
    # This is useful to know because when a `yield` happens,
    # we more or less create a new stack frame that has the same
    # local variables as this frame, because the block will need
    # to access that frame's variables.
    # It's -1 if the value is not present.
    block_caller_frame_index : Int32,
    # When a `yield` happens we copy the frame pointed by
    # `block_caller_frame_index`. If a `return` happens inside
    # that block we need to return from that frame (the `def`s one.)
    # With `real_frame_index` we know where that frame is actually
    # in the call stack (the original, not the copy) and we can
    # go back to just before that frame when a `return` happens.
    real_frame_index : Int32

  getter context : Context
  getter? pry : Bool
  @pry_node : ASTNode?
  @pry_max_target_frame : Int32?

  getter local_vars : LocalVars
  getter stack : Pointer(UInt8)
  getter stack_top : Pointer(UInt8)

  property decompile = true
  property argv : Array(String)

  def initialize(@context : Context, meta_vars : MetaVars? = nil)
    @local_vars = LocalVars.new(@context)
    @argv = [] of String

    @instructions = [] of Instruction
    @nodes = {} of Int32 => ASTNode

    # TODO: what if the stack is exhausted?
    @stack = Pointer(Void).malloc(8 * 1024 * 1024).as(UInt8*)
    @stack_top = @stack
    @call_stack = [] of CallFrame

    @block_level = 0

    @compiled_def = nil
    @pry = false
    @pry_node = nil
    @pry_max_target_frame = nil
  end

  def initialize(interpreter : Interpreter, compiled_def : CompiledDef, stack : Pointer(UInt8), @block_level : Int32)
    @context = interpreter.context
    @local_vars = compiled_def.local_vars.dup
    @argv = interpreter.@argv

    @instructions = [] of Instruction
    @nodes = {} of Int32 => ASTNode

    @stack = stack
    @stack_top = @stack
    # TODO: copy the call stack from the main interpreter
    @call_stack = [] of CallFrame

    @compiled_def = compiled_def
    @pry = false
    @pry_node = nil
    @pry_max_target_frame = nil
  end

  def interpret(node : ASTNode, meta_vars : MetaVars) : Value
    compiled_def = @compiled_def

    # Declare local variables

    # Don't declare local variables again if we are in the middle of pry
    unless compiled_def
      migrate_local_vars(@local_vars, meta_vars)

      meta_vars.each do |name, meta_var|
        meta_var_type = meta_var.type?

        # A meta var might end up without a type if it's assigned a value
        # in a branch that's never executed/typed, and never read afterwards
        next unless meta_var_type

        existing_type = @local_vars.type?(name, 0)
        if existing_type
          if existing_type != meta_var.type
            raise "BUG: can't change type of local variable #{name} from #{existing_type} to #{meta_var.type} yet"
          end
        else
          @local_vars.declare(name, meta_var_type)
        end
      end
    end

    # TODO: top_level or not
    compiler =
      if compiled_def
        Compiler.new(@context, @local_vars, scope: compiled_def.owner, def: compiled_def.def)
      else
        Compiler.new(@context, @local_vars)
      end
    compiler.block_level = @block_level
    compiler.compile(node)

    @instructions = compiler.instructions
    @nodes = compiler.nodes

    if @decompile && @context.decompile
      if compiled_def
        puts "=== #{compiled_def.owner}##{compiled_def.def.name} ==="
      else
        puts "=== top-level ==="
      end
      puts @local_vars
      puts Disassembler.disassemble(@context, @instructions, @nodes, @local_vars)

      if compiled_def
        puts "=== #{compiled_def.owner}##{compiled_def.def.name} ==="
      else
        puts "=== top-level ==="
      end
    end

    time = Time.monotonic
    value = interpret(node, node.type)
    if @context.stats
      puts "Elapsed: #{Time.monotonic - time}"
    end

    value
  end

  private def interpret(node : ASTNode, node_type : Type) : Value
    stack_bottom = @stack

    # Shift stack to leave ream for local vars
    # Previous runs that wrote to local vars would have those values
    # written to @stack alreay
    stack_bottom_after_local_vars = stack_bottom + @local_vars.max_bytesize
    stack = stack_bottom_after_local_vars

    # Reserve space for constants
    @context.constants_memory = @context.constants_memory.realloc(@context.constants.bytesize)

    # Reserve space for class vars
    @context.class_vars_memory = @context.class_vars_memory.realloc(@context.class_vars.bytesize)

    @context.class_vars.each_initialized_index do |index|
      @context.class_vars_memory[index] = 1_u8
    end

    instructions = @instructions
    nodes = @nodes
    ip = instructions.to_unsafe
    return_value = Pointer(UInt8).null

    compiled_def = @compiled_def
    if compiled_def
      a_def = compiled_def.def
    else
      a_def = Def.new("<top-level>", body: node)
      a_def.owner = program
      a_def.vars = program.vars
    end

    @call_stack << CallFrame.new(
      compiled_def: CompiledDef.new(
        context: @context,
        def: a_def,
        owner: compiled_def.try(&.owner) || a_def.owner,
        args_bytesize: 0,
        instructions: instructions,
        nodes: @nodes,
        local_vars: @local_vars,
      ),
      instructions: instructions,
      nodes: nodes,
      ip: ip,
      stack: stack,
      stack_bottom: stack_bottom,
      block_caller_frame_index: -1,
      real_frame_index: 0,
    )

    while true
      if @context.trace
        puts

        call_frame = @call_stack.last
        a_def = call_frame.compiled_def.def
        offset = (ip - instructions.to_unsafe).to_i32
        puts "In: #{a_def.owner}##{a_def.name}"
        node = nodes[offset]?
        puts "Node: #{node}" if node
        puts Slice.new(@stack, stack - @stack).hexdump

        Disassembler.disassemble_one(@context, instructions, offset, nodes, current_local_vars, STDOUT)
        puts
      end

      if @pry
        pry_max_target_frame = @pry_max_target_frame
        if !pry_max_target_frame || @call_stack.last.real_frame_index <= pry_max_target_frame
          pry(ip, instructions, nodes, stack_bottom, stack)
        end
      end

      op_code = next_instruction OpCode

      {% begin %}
        case op_code
          {% for name, instruction in Crystal::Repl::Instructions %}
            {% operands = instruction[:operands] %}
            {% pop_values = instruction[:pop_values] %}

            in .{{name.id}}?
              {% for operand in operands %}
                {{operand.var}} = next_instruction {{operand.type}}
              {% end %}

              {% for pop_value, i in pop_values %}
                {% pop = pop_values[pop_values.size - i - 1] %}
                {{ pop.var }} = stack_pop({{pop.type}})
              {% end %}

              {% if instruction[:push] %}
                stack_push({{instruction[:code]}})
              {% else %}
                {{instruction[:code]}}
              {% end %}
          {% end %}
        end
      {% end %}

      if @context.trace
        puts Slice.new(@stack, stack - @stack).hexdump
      end
    end

    if stack != stack_bottom_after_local_vars
      raise "BUG: data left on stack (#{stack - stack_bottom_after_local_vars} bytes): #{Slice.new(@stack, stack - @stack)}"
    end

    Value.new(@context, return_value, node_type)
  end

  private def migrate_local_vars(current_local_vars, next_meta_vars)
    # Check if any existing local variable size changed.
    # If so, it means we need to put them inside a union,
    # or make the union bigger.
    current_names = current_local_vars.names_at_block_level_zero
    needs_migration = current_names.any? do |current_name|
      current_type = current_local_vars.type(current_name, 0)
      next_type = next_meta_vars[current_name].type
      aligned_sizeof_type(current_type) != aligned_sizeof_type(next_type)
    end

    unless needs_migration
      # Always start with fresh variables, because union types might have changed
      @local_vars = LocalVars.new(@context)
      return
    end

    current_memory = Pointer(UInt8).malloc(current_local_vars.current_bytesize)
    @stack.copy_to(current_memory, current_local_vars.current_bytesize)

    stack = @stack
    current_names.each do |current_name|
      current_type = current_local_vars.type(current_name, 0)
      next_type = next_meta_vars[current_name].type
      current_type_size = aligned_sizeof_type(current_type)
      next_type_size = aligned_sizeof_type(next_type)

      if current_type_size == next_type_size
        # Doesn't need a migration, so we copy it as-is
        stack.copy_from(current_memory, current_type_size)
      else
        # Needs a migration
        case next_type
        when MixedUnionType
          case current_type
          when PrimitiveType, NonGenericClassType, GenericClassInstanceType
            stack.as(Int32*).value = type_id(current_type)
            (stack + type_id_bytesize).copy_from(current_memory, current_type_size)
          when ReferenceUnionType, NilableReferenceUnionType, VirtualType
            reference = stack.as(UInt8**).value
            if reference.null?
              stack.clear(next_type_size)
            else
              stack.as(Int32*).value = reference.as(Int32*).value
              (stack + type_id_bytesize).copy_from(current_memory, current_type_size)
            end
          when MixedUnionType
            # Copy the union type id
            stack.as(Int32*).value = current_memory.as(Int32*).value

            # Copy the value
            (stack + type_id_bytesize).copy_from(current_memory + type_id_bytesize, current_type_size)
          else
            # There might not be other cases to handle, but just in case...
            raise "BUG: missing local var migration from #{current_type} to #{next_type} (#{current_type.class} to #{next_type.class})"
          end
        else
          # I don't this a migration is ever needed unless the target type is a MixedUnionType,
          # but just in case...
          raise "BUG: missing local var migration from #{current_type} to #{next_type}"
        end
      end

      stack += next_type_size
      current_memory += current_type_size
    end

    # Need to start with fresh local variables
    @local_vars = LocalVars.new(@context)
  end

  private def current_local_vars
    if call_frame = @call_stack.last?
      call_frame.compiled_def.local_vars
    else
      @local_vars
    end
  end

  private macro call(compiled_def,
                     block_caller_frame_index = -1)
    # At the point of a call like:
    #
    #     foo(x, y)
    #
    # x and y will already be in the stack, ready to be used
    # as the function arguments in the target def.
    #
    # After the call, we want the stack to be at the point
    # where it doesn't have the call args, ready to push
    # return call's return value.
    %stack_before_call_args = stack - {{compiled_def}}.args_bytesize

    # Clear the portion after the call args and upto the def local vars
    # because it might contain garbage data from previous block calls or
    # method calls.
    %size_to_clear = {{compiled_def}}.local_vars.max_bytesize - {{compiled_def}}.args_bytesize
    if %size_to_clear < 0
      raise "OH NO, size to clear DEF is: #{ %size_to_clear }"
    end

    stack.clear(%size_to_clear)

    @call_stack[-1] = @call_stack.last.copy_with(
      ip: ip,
      stack: %stack_before_call_args,
    )

    %call_frame = CallFrame.new(
      compiled_def: {{compiled_def}},
      instructions: {{compiled_def}}.instructions,
      nodes: {{compiled_def}}.nodes,
      ip: {{compiled_def}}.instructions.to_unsafe,
      # We need to adjust the call stack to start right
      # after the target def's local variables.
      stack: %stack_before_call_args + {{compiled_def}}.local_vars.max_bytesize,
      stack_bottom: %stack_before_call_args,
      block_caller_frame_index: {{block_caller_frame_index}},
      real_frame_index: @call_stack.size,
    )

    @call_stack << %call_frame

    instructions = %call_frame.compiled_def.instructions
    nodes = %call_frame.compiled_def.nodes
    ip = %call_frame.ip
    stack = %call_frame.stack
    stack_bottom = %call_frame.stack_bottom
  end

  private macro call_with_block(compiled_def)
    call({{compiled_def}}, block_caller_frame_index: @call_stack.size - 1)
  end

  private macro call_block(compiled_block)
    # At this point the stack has the yield expressions, so after the call
    # we must go back to before the yield expressions
    %stack_before_call_args = stack - {{compiled_block}}.args_bytesize
    @call_stack[-1] = @call_stack.last.copy_with(
      ip: ip,
      stack: %stack_before_call_args,
    )

    %block_caller_frame_index = @call_stack.last.block_caller_frame_index

    copied_call_frame = @call_stack[%block_caller_frame_index].copy_with(
      instructions: {{compiled_block}}.instructions,
      nodes: {{compiled_block}}.nodes,
      ip: {{compiled_block}}.instructions.to_unsafe,
      stack: stack,
    )
    @call_stack << copied_call_frame

    instructions = copied_call_frame.instructions
    nodes = copied_call_frame.nodes
    ip = copied_call_frame.ip
    stack_bottom = copied_call_frame.stack_bottom

    %offset_to_clear = {{compiled_block}}.locals_bytesize_start + {{compiled_block}}.args_bytesize
    %size_to_clear = {{compiled_block}}.locals_bytesize_end - {{compiled_block}}.locals_bytesize_start - {{compiled_block}}.args_bytesize
    if %size_to_clear < 0
      raise "OH NO, size to clear BLOCK is: #{ %size_to_clear }"
    end

    # Clear the portion after the block args and upto the block local vars
    # because it might contain garbage data from previous block calls or
    # method calls.
    #
    # stack ... locals ... locals_bytesize_start ... args_bytesize ... locals_bytesize_end
    #                                                            [ ..................... ]
    #                                                                   delete this
    (stack_bottom + %offset_to_clear).clear(%size_to_clear)
  end

  private macro lib_call(lib_function)
    %target_def = lib_function.def
    %cif = lib_function.call_interface
    %fn = lib_function.symbol
    %args_bytesizes = lib_function.args_bytesizes
    %proc_args = lib_function.proc_args

    # Assume C calls don't have more than 100 arguments
    # TODO: use the stack for this?
    %pointers = uninitialized StaticArray(Pointer(Void), 100)
    %offset = 0

    %i = %args_bytesizes.size - 1
    %args_bytesizes.reverse_each do |arg_bytesize|
      # If an argument is a Proc, in the stack it's {pointer, closure_data},
      # where pointer is actually the object_id of a CompiledDef.
      # TODO: check that closure_data is null and raise otherwise
      # We need to wrap the Proc in an FFI::Closure. proc_args[%i] will have
      # the CallInterface for the Proc.
      # We copy the CompiledDef from the stack and into a FFIClosureContext,
      # include also the interpreter, and put that in the stack to later
      # pass it to the FFI call below.
      if %proc_arg_cif = %proc_args[%i]
        proc_compiled_def = (stack - %offset - arg_bytesize).as(CompiledDef*).value
        closure_context = @context.ffi_closure_context(self, proc_compiled_def)

        %closure = FFI::Closure.new(%proc_arg_cif, @context.ffi_closure_fun, closure_context.as(Void*))
        (stack - %offset - arg_bytesize).as(Int64*).value = %closure.to_unsafe.unsafe_as(Int64)
      end

      %pointers[%i] = (stack - %offset - arg_bytesize).as(Void*)
      %offset += arg_bytesize
      %i -= 1
    end

    # Remember the stack top so that if a callback is called from C
    # and back to the interpreter, we can continue using the stack
    # from this point.
    @stack_top = stack

    %cif.call(%fn, %pointers.to_unsafe, stack.as(Void*))

    %return_bytesize = inner_sizeof_type(%target_def.type)
    %aligned_return_bytesize = align(%return_bytesize)

    (stack - %offset).move_from(stack, %return_bytesize)
    stack = stack - %offset + %return_bytesize

    stack_grow_by(%aligned_return_bytesize - %return_bytesize)
  end

  private macro leave(size)
    # Remember the point the stack reached
    %old_stack = stack
    %previous_call_frame = @call_stack.pop

    leave_after_pop_call_frame(%old_stack, %previous_call_frame, {{size}})
  end

  private macro leave_def(size)
    # Remember the point the stack reached
    %old_stack = stack
    %previous_call_frame = @call_stack.pop

    until @call_stack.size == %previous_call_frame.real_frame_index
      @call_stack.pop
    end

    leave_after_pop_call_frame(%old_stack, %previous_call_frame, {{size}})
  end

  private macro break_block(size)
    # Remember the point the stack reached
    %old_stack = stack
    %previous_call_frame = @call_stack.pop

    until @call_stack.size - 1 == %previous_call_frame.real_frame_index
      @call_stack.pop
    end

    leave_after_pop_call_frame(%old_stack, %previous_call_frame, {{size}})
  end

  private macro leave_after_pop_call_frame(old_stack, previous_call_frame, size)
    if @call_stack.empty?
      return_value = Pointer(Void).malloc({{size}}).as(UInt8*)
      return_value.copy_from(stack_bottom_after_local_vars, {{size}})
      stack_shrink_by({{size}})
      break
    else
      %old_stack = {{old_stack}}
      %previous_call_frame = {{previous_call_frame}}
      %call_frame = @call_stack.last

      # Restore ip, instructions and stack bottom
      instructions = %call_frame.instructions
      nodes = %call_frame.nodes
      ip = %call_frame.ip
      stack_bottom = %call_frame.stack_bottom
      stack = %call_frame.stack

      # Ccopy the return value
      stack_move_from(%old_stack - {{size}}, {{size}})

      # TODO: clean up stack
    end
  end

  private macro set_ip(ip)
    ip = instructions.to_unsafe + {{ip}}
  end

  private macro set_local_var(index, size)
    stack_move_to(stack_bottom + {{index}}, {{size}})
  end

  private macro get_local_var(index, size)
    stack_move_from(stack_bottom + {{index}}, {{size}})
  end

  private macro get_local_var_pointer(index)
    stack_bottom + {{index}}
  end

  private macro get_ivar_pointer(offset)
    self_class_pointer + offset
  end

  private macro const_initialized?(index)
    # TODO: make this atomic
    %initialized = @context.constants_memory[{{index}}]
    if %initialized == 1_u8
      true
    else
      @context.constants_memory[{{index}}] = 1_u8
      false
    end
  end

  private macro get_const(index, size)
    stack_move_from(get_const_pointer(index), {{size}})
  end

  private macro get_const_pointer(index)
    @context.constants_memory + {{index}} + Constants::OFFSET_FROM_INITIALIZED
  end

  private macro set_const(index, size)
    stack_move_to(get_const_pointer(index), {{size}})
  end

  private macro class_var_initialized?(index)
    # TODO: make this atomic
    %initialized = @context.class_vars_memory[{{index}}]
    if %initialized == 1_u8
      true
    else
      @context.class_vars_memory[{{index}}] = 1_u8
      false
    end
  end

  private macro get_class_var(index, size)
    stack_move_from(get_class_var_pointer(index), {{size}})
  end

  private macro set_class_var(index, size)
    stack_move_to(get_class_var_pointer(index), {{size}})
  end

  private macro get_class_var_pointer(index)
    @context.class_vars_memory + {{index}} + ClassVars::OFFSET_FROM_INITIALIZED
  end

  private macro atomicrmw_op(op)
    case element_size
    when 1
      i8 = Atomic::Ops.atomicrmw({{op}}, ptr, value.to_u8!, :sequentially_consistent, false)
      stack_push(i8)
    when 2
      i16 = Atomic::Ops.atomicrmw({{op}}, ptr.as(UInt16*), value.to_u16!, :sequentially_consistent, false)
      stack_push(i16)
    when 4
      i32 = Atomic::Ops.atomicrmw({{op}}, ptr.as(UInt32*), value.to_u32!, :sequentially_consistent, false)
      stack_push(i32)
    when 8
      i64 = Atomic::Ops.atomicrmw({{op}}, ptr.as(UInt64*), value.to_u64!, :sequentially_consistent, false)
      stack_push(i64)
    else
      raise "BUG: unhandled element size for store_atomic instruction: #{element_size}"
    end
  end

  private macro pry
    self.pry = true
  end

  def pry=(@pry)
    @pry = pry

    unless pry
      @pry_node = nil
      @pry_max_target_frame = nil
    end
  end

  private macro next_instruction(t)
    value = ip.as({{t}}*).value
    ip += sizeof({{t}})
    value
  end

  private macro self_class_pointer
    get_local_var_pointer(0).as(Pointer(Pointer(UInt8))).value
  end

  private macro stack_pop(t)
    %aligned_size = align(sizeof({{t}}))
    %value = (stack - %aligned_size).as({{t}}*).value
    stack_shrink_by(%aligned_size)
    %value
  end

  private macro stack_push(value)
    %temp = {{value}}
    stack.as(Pointer(typeof({{value}}))).value = %temp

    %size = sizeof(typeof({{value}}))
    %aligned_size = align(%size)
    stack += %size
    stack_grow_by(%aligned_size - %size)
  end

  private macro stack_copy_to(pointer, size)
    (stack - {{size}}).copy_to({{pointer}}, {{size}})
  end

  private macro stack_move_to(pointer, size)
    %size = {{size}}
    %aligned_size = align(%size)
    (stack - %aligned_size).copy_to({{pointer}}, %size)
    stack_shrink_by(%aligned_size)
  end

  private macro stack_move_from(pointer, size)
    %size = {{size}}
    %aligned_size = align(%size)

    stack.copy_from({{pointer}}, %size)
    stack += %size
    stack_grow_by(%aligned_size - %size)
  end

  private macro stack_grow_by(size)
    stack_clear({{size}})
    stack += {{size}}
  end

  private macro stack_shrink_by(size)
    stack -= {{size}}
    stack_clear({{size}})
  end

  private macro stack_clear(size)
    # TODO: clearing the stack after every step is very slow!
    stack.clear({{size}})
  end

  def aligned_sizeof_type(type : Type) : Int32
    @context.aligned_sizeof_type(type)
  end

  def inner_sizeof_type(type : Type) : Int32
    @context.inner_sizeof_type(type)
  end

  private def type_id(type : Type) : Int32
    @context.type_id(type)
  end

  private def type_from_type_id(id : Int32) : Type
    @context.type_from_id(id)
  end

  private macro type_id_bytesize
    8
  end

  private def align(value : Int32)
    @context.align(value)
  end

  private def program
    @context.program
  end

  private def argc_unsafe
    argv.size + 1
  end

  @argv_unsafe : Pointer(Pointer(UInt8))?

  private def argv_unsafe
    @argv_unsafe ||= begin
      pointers = Pointer(Pointer(UInt8)).malloc(argc_unsafe)
      # The program name
      pointers[0] = "icr".to_unsafe

      argv.each_with_index do |arg, i|
        pointers[i + 1] = arg.to_unsafe
      end

      pointers
    end
  end

  private def spawn_interpreter(fiber : Void*, fiber_main : Void*) : Void*
    spawned_fiber = Fiber.new do
      # `fiber_main` is the pointer type of a `Proc(Fiber, Nil)`.
      # `fiber` is the fiber that we need to pass `fiber_main` to kick off the fiber.
      #
      # To make it work, we construct a call like this:
      #
      # ```
      # fiber_main.call(fiber)
      # ```

      fiber_type = @context.program.types["Fiber"]
      nil_type = @context.program.nil_type
      proc_type = @context.program.proc_of([fiber_type, nil_type] of Type)

      meta_vars = MetaVars.new
      meta_vars["fiber_main"] = MetaVar.new("fiber_main", proc_type)
      meta_vars["fiber"] = MetaVar.new("fiber", fiber_type)

      call = Call.new(Var.new("fiber_main"), "call", Var.new("fiber"))
      main_visitor = MainVisitor.new(@context.program, vars: meta_vars, meta_vars: meta_vars)
      call.accept main_visitor

      interpreter = Interpreter.new(@context, meta_vars: meta_vars)

      # We also need to put the data for `fiber_main` and `fiber` on the stack.
      stack = interpreter.stack

      # Here comes `fiber_main`
      # Put the proc pointer first
      stack.as(Void**).value = fiber_main
      stack += sizeof(Void*)

      # Put the closure data, which is nil
      stack.as(Void**).value = Pointer(Void).null
      stack += sizeof(Void*)

      # Now comes `fiber`
      stack.as(Void**).value = fiber

      interpreter.interpret(call, main_visitor.meta_vars)

      nil
    end
    spawned_fiber.as(Void*)
  end

  private def swapcontext(current_context : Void*, new_context : Void*)
    # current_fiber = current_context.as(Fiber*).value
    new_fiber = new_context.as(Fiber*).value

    # We directly resume the next fiber.
    # TODO: is this okay? We totally ignore the scheduler here!
    new_fiber.resume
  end

  private def pry(ip, instructions, nodes, stack_bottom, stack)
    call_frame = @call_stack.last
    compiled_def = call_frame.compiled_def
    a_def = compiled_def.def
    local_vars = compiled_def.local_vars
    offset = (ip - instructions.to_unsafe).to_i32
    node = nodes[offset]?
    pry_node = @pry_node
    if node && (location = node.location) && different_node_line?(node, pry_node)
      whereami(a_def, location)

      # puts
      # puts Slice.new(stack_bottom, stack - stack_bottom).hexdump
      # puts

      # Remember the portion from stack_bottom + local_vars.max_bytesize up to stack
      # because it might happen that the child interpreter will overwrite some
      # of that if we already have some values in the stack past the local vars
      data_size = stack - (stack_bottom + local_vars.max_bytesize)
      data = Pointer(Void).malloc(data_size).as(UInt8*)
      data.copy_from(stack_bottom + local_vars.max_bytesize, data_size)

      gatherer = LocalVarsGatherer.new(location, a_def)
      gatherer.gather
      meta_vars = gatherer.meta_vars
      block_level = gatherer.block_level

      main_visitor = MainVisitor.new(
        @context.program,
        vars: meta_vars,
        meta_vars: meta_vars,
        typed_def: a_def)
      main_visitor.scope = compiled_def.owner
      main_visitor.path_lookup = compiled_def.owner # TODO: this is probably not right

      interpreter = Interpreter.new(self, compiled_def, stack_bottom, block_level)

      while @pry
        # TODO: supoort multi-line expressions

        line = Readline.readline("pry> ", add_history: true)
        unless line
          self.pry = false
          break
        end

        case line
        when "continue"
          self.pry = false
          break
        when "step"
          @pry_node = node
          @pry_max_target_frame = nil
          break
        when "next"
          @pry_node = node
          @pry_max_target_frame = @call_stack.last.real_frame_index
          break
        when "finish"
          @pry_node = node
          @pry_max_target_frame = @call_stack.last.real_frame_index - 1
          break
        when "whereami"
          whereami(a_def, location)
          next
        when "disassemble"
          puts Disassembler.disassemble(@context, compiled_def)
          next
        end

        begin
          parser = Parser.new(
            line,
            string_pool: @context.program.string_pool,
            def_vars: [interpreter.local_vars.names.to_set],
          )
          line_node = parser.parse

          line_node = @context.program.normalize(line_node)
          line_node = @context.program.semantic(line_node, main_visitor: main_visitor)

          value = interpreter.interpret(line_node, meta_vars)
          puts value
        rescue ex : Crystal::CodeError
          ex.color = true
          ex.error_trace = true
          puts ex
          next
        rescue ex : Exception
          ex.inspect_with_backtrace(STDOUT)
          next
        end
      end

      # Restore the stack data in case it tas overwritten
      (stack_bottom + local_vars.max_bytesize).copy_from(data, data_size)
    end
  end

  private def whereami(a_def : Def, location : Location)
    filename = location.filename
    line_number = location.line_number
    column_number = location.column_number

    if filename.is_a?(String)
      puts "From: #{Crystal.relative_filename(filename)}:#{line_number}:#{column_number} #{a_def.owner}##{a_def.name}:"
    else
      puts "From: #{location} #{a_def.owner}##{a_def.name}:"
    end

    puts

    lines =
      case filename
      in String
        File.read_lines(filename)
      in VirtualFile
        filename.source.lines.to_a
      in Nil
        nil
      end

    return unless lines

    min_line_number = {location.line_number - 5, 1}.max
    max_line_number = {location.line_number + 5, lines.size}.min

    max_line_number_size = max_line_number.to_s.size

    min_line_number.upto(max_line_number) do |line_number|
      line = lines[line_number - 1]
      if line_number == location.line_number
        print " => "
      else
        print "    "
      end

      # Pad line number if needed
      line_number_size = line_number.to_s.size
      (max_line_number_size - line_number_size).times do
        print ' '
      end

      print line_number.colorize.blue
      print ": "
      puts SyntaxHighlighter.highlight(line)
    end
    puts
  end

  private def different_node_line?(node : ASTNode, previous_node : ASTNode?)
    return true unless previous_node
    return true if node.location.not_nil!.filename != previous_node.location.not_nil!.filename

    node.location.not_nil!.line_number != previous_node.location.not_nil!.line_number
  end
end
