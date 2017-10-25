# Return the CodeInfo method body for signature `S` and `world`,
# if it exists in the method table. Otherwise, return `nothing`.
function lookup_method_body(::Type{S},
                            world::UInt = typemax(UInt),
                            debug::Bool = false) where {S<:Tuple}
    if debug
        println("-----------------------------------")
        println("LOOKING UP CODEINFO FOR:")
        println("\tSIGNATURE: ", S)
        println("\tWORLD: ", world)
    end
    results = _lookup_method_body(S, world)
    results === nothing && return nothing
    method, code_info = results
    debug && println("LOOKED UP METHOD: ", method)
    debug && println("LOOKED UP CODEINFO: ", code_info)
    return code_info
end

const GETFIELD_PLACEHOLDER = :GETFIELD_PLACEHOLDER

function _lookup_method_body(::Type{S}, world::UInt = typemax(UInt)) where {S<:Tuple}
    # retrieve Method
    _methods = Base._methods_by_ftype(S, -1, world)
    length(_methods) == 1 || return nothing
    type_signature, raw_static_params, method = first(_methods)

    # retrieve CodeInfo
    method_instance = Core.Inference.code_for_method(method, type_signature, raw_static_params, world, false)
    code_info = Core.Inference.retrieve_code_info(method_instance)
    isa(code_info, CodeInfo) || return nothing

    # unpack useful info
    method_signature = method.sig
    static_params = Any[raw_static_params...]
    n_actual_args = fieldcount(S) - 1
    n_method_args = Int64(method.nargs) - 1

    # offset argument slots and substitute static parameters
    body = Expr(:block)
    body.args = code_info.code
    Base.Core.Inference.substitute!(body, 0, Any[], method_signature, static_params, 1, :propagate)

    # reassign arguments and fix slotnames/slotflags
    new_slotnames = Any[code_info.slotnames[1], OVERDUB_ARGS_SYMBOL, code_info.slotnames[2:end]...]
    new_slotflags = Any[code_info.slotflags[1], 0x00,                code_info.slotflags[2:end]...]
    reassignments = Any[]
    for i in 1:n_method_args
        slot = i + 2
        actual_argument = Expr(:call, GETFIELD_PLACEHOLDER, SlotNumber(2), i)
        push!(reassignments, :($(SlotNumber(slot)) = $actual_argument))
        new_slotflags[slot] |= 0x01 << 0x01 # make sure the "assigned" bitflag is set
    end
    if method.isva
        final_arguments = Expr(:call, GlobalRef(Core, :tuple))
        for i in n_method_args:n_actual_args
            push!(final_arguments.args, Expr(:call, GETFIELD_PLACEHOLDER, SlotNumber(2), i))
        end
        reassignments[end] = :($(SlotNumber(n_method_args + 2)) = $final_arguments)
    end
    code_info.code = Any[code_info.code[1], reassignments..., code_info.code[2:end]...]
    code_info.slotnames = new_slotnames
    code_info.slotflags = new_slotflags

    return method, code_info
end

############################################################################################

#=
function _lookup_method_body(::Type{S}, arg_names::Vector,
                             world::UInt = typemax(UInt)) where {S<:Tuple}
    # retrieve initial Method + CodeInfo
    _methods = Base._methods_by_ftype(S, -1, world)
    length(_methods) == 1 || return nothing
    type_signature, raw_static_params, method = first(_methods)
    method_instance = Core.Inference.code_for_method(method, type_signature, raw_static_params, world, false)
    method_signature = method.sig
    static_params = Any[raw_static_params...]
    code_info = Core.Inference.retrieve_code_info(method_instance)
    isa(code_info, CodeInfo) || return nothing

    # substitute static parameters/varargs
    body = Expr(:block)
    body.args = code_info.code
    if method.isva
        nargs = Int64(method.nargs)
        new_nargs = length(arg_names) + 1
        if new_nargs < nargs # then the final varargs argument is an empty tuple
            offset = 0
            new_slots = Any[SlotNumber(i) for i in 1:(nargs - 1)]
            push!(new_slots, Expr(:call, GlobalRef(Core, :tuple)))
            Base.Core.Inference.substitute!(body, nargs, new_slots, method_signature, static_params, offset, :propagate)
        else
            new_slotnames = code_info.slotnames[1:(nargs - 1)]
            new_slotflags = code_info.slotflags[1:(nargs - 1)]
            for i in nargs:new_nargs
                push!(new_slotnames, arg_names[i - 1])
                push!(new_slotflags, 0x00)
            end
            append!(new_slotnames, code_info.slotnames[(nargs + 1):end])
            append!(new_slotflags, code_info.slotflags[(nargs + 1):end])
            offset = new_nargs - nargs
            vararg_tuple = Expr(:call, GlobalRef(Core, :tuple), [SlotNumber(i) for i in nargs:new_nargs]...)
            new_slots = Any[SlotNumber(i) for i in 1:(nargs - 1)]
            push!(new_slots, vararg_tuple)
            Base.Core.Inference.substitute!(body, new_nargs, new_slots, method_signature, static_params, offset, :propagate)
            code_info.slotnames = new_slotnames
            code_info.slotflags = new_slotflags
        end
    else
        Base.Core.Inference.substitute!(body, 0, Any[], method_signature, static_params, 0, :propagate)
    end

    return method, code_info
end
=#
