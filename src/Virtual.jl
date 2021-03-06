module Virtual
export @virtual, @override
include("utils.jl")

import Tricks
@compile_only using MLStyle
@compile_include "reflection.jl"

import Serialization

"""
A reference to store non-concrete arguments.
It helps to trigger code line and compilation of generated functions.
(P.S: I'm sooooooooooooooo cool!)
"""
struct GenWrapper
    refval :: Any
end

@inline function gen_wrap(::Type{T}, x) where T
    isconcretetype(T) && return x
    return GenWrapper(x)
end

@inline gen_unwrap(x::GenWrapper) = x.refval
@inline gen_unwrap(x) = x

function invoke_virt end

struct Signature{Args} end

mutable struct DispatchTree
    type
    specialized::Vector{DispatchTree}
end

function split_sig(@nospecialize(t))
    typevars = Core.TypeVar[]
    while t isa UnionAll
        push!(typevars, t.var)
        t = t.body
    end
    tfunc = t.parameters[1]
    n = length(t.parameters) - 1
    t = Tuple{t.parameters[2:end]...}
    while !isempty(typevars)
        t = UnionAll(pop!(typevars), t)
    end
    return (n, tfunc, t)
end

function generate_call!(@nospecialize(pairs::Vector{<:Pair}), @nospecialize(dt::DispatchTree), @nospecialize(args))
    for spec in dt.specialized
        generate_call!(pairs, spec, args)
    end
    nargs = length(Base.unwrap_unionall(dt.type).parameters)
    cond = if dt.type isa DataType
        pars = collect(dt.type.parameters)
        Expr(:(&&), [:($(args[i]) isa $(pars[i])) for i = 2:nargs]...)
    else
        arg = Expr(:tuple, args...)
        :($arg isa $(dt.type)) # generic
    end
    push!(
        pairs,
        cond => :($unsafe_dispatch($(dt.type)).instance($([:($(args[i])) for i = 2:nargs]...))))
end

function generate_call(@nospecialize(dt::DispatchTree), @nospecialize(arg))
    pairs = Pair{Any, Any}[]
    generate_call!(pairs, dt, arg)
    return pairs
end

function find_most_general(@nospecialize(ts))
    for i = eachindex(ts)
        for j = eachindex(ts)
            i === j && continue
            Core.Compiler.morespecific(ts[j], ts[i]) && continue
            @goto not_found
        end
        return i
        @label not_found
    end
    return -1
end

function create_dispatch_tree(@nospecialize(ts))
    type = nothing
    specialized = DispatchTree[]
    if length(ts) === 1
        type = ts[1]
        return DispatchTree(type, specialized)
    end
    most_general_index = find_most_general(ts)
    if most_general_index === -1
        reprs = join(ts, ", ")
        error("No most general type found for methods $(reprs)")
    end
    split = Set{Any}[]
    for i in eachindex(ts)
        t = ts[i]
        if i === most_general_index
            type = t
            continue
        end
        for group in split
            if any((t <: each_t || t >: each_t) for each_t in group)
                push!(group, t)
                break
            end
        end
        push!(split, Set{Any}([t]))
    end
    for group in split
        push!(
            specialized,
            create_dispatch_tree(
                collect(Any, group)))
    end
    return DispatchTree(type, specialized)
end

@inline @generated function find_overrided_methods(_T::Type{T}) where T
    sigs = [split_sig(m.sig)[3] for m in Tricks._methods(typeof(invoke_virt), T)]
    ci = Tricks.create_codeinfo_with_returnvalue([Symbol("#self#"), :_T], [:T], (:T,), QuoteNode(Val(Tuple{sigs...})))
    ci.edges = Tricks._method_table_all_edges_all_methods(typeof(invoke_virt), T)
    return ci
end

@inline @generated function apply_switch(::Val{Tup}, args::Vararg{Any,N}) where {Tup, N}
    sigs = collect(Tup.parameters)
    init=:($error("method not found for " * $string(args)))
    if isempty(sigs)
        return init
    end
    dt = create_dispatch_tree(sigs)
    sym_args = [gensym("_arg$i") for i = 1:N]
    
    pairs = generate_call(dt, sym_args)
    ex = foldr(1:length(pairs), init=init) do l, r
        cond, invocation = pairs[l]
        head = l === 1 ? (:if) : (:elseif)
        Expr(head, cond, invocation, r)
    end
    Expr(:block, [:($(sym_args[i]) = $gen_unwrap(args[$i])) for i = 1:length(sym_args)]..., ex)
end

const sym_selected_func = Symbol("Virtual::selected_func")
const sym_impl_func = Symbol("Virtual::impl_func")

_find_type(::Undefined) = Any
_find_type(x) = x

function unsafe_dispatch end

_mk_where(e, typars) = isempty(typars) ? e : Expr(:where, e, typars...)

function _mk_virtual(__module__ :: Module, __source__ :: LineNumberNode, func_def::FuncInfo)
    func_def.name isa Undefined && throw(create_exception(__source__, "virtual function must have a name"))
    isempty(func_def.kwPars) || throw(create_exception(__source__, "virtual function does not take keyword parameters"))
    any(par.isVariadic for par in func_def.pars) && throw(create_exception(__source__, "virtual function does not take variadic parameters"))
    argtypes = [ _find_type(par.type) for par in func_def.pars ]
    arguments = [ Expr(:call, gen_wrap, partype, par.name) for (partype, par) in zip(argtypes, func_def.pars) ]
    argtypes = [ _find_type(par.type) for par in func_def.pars ]
    arg = Expr(:tuple, func_def.name, arguments...)
    targ = Expr(:curly, Tuple, :($typeof($(func_def.name))), argtypes...)
    new_func_def = replace_field(
        func_def,
        ln = __source__,
        body = Expr(:block,
            # Expr(:meta, :noinline),
            __source__,
            __source__,
            :($sym_impl_func = $find_overrided_methods($targ)),
            :(return $apply_switch($sym_impl_func, $(func_def.name), $(arguments...)))))
    
    edge_def = replace_field(
        func_def,
        ln = __source__,
        name = :($Virtual.invoke_virt),
        pars = ParamInfo[
            ParamInfo(name = sym_selected_func, type = :($typeof($(func_def.name)))),
            func_def.pars...
        ],
        body = Expr(:block, __source__, __source__, :nothing))
    
    impl_name = gensym()
    
    sig = Expr(:curly, Type,
        _mk_where(Expr(:curly, Tuple, :($typeof($(func_def.name))), argtypes...), to_expr.(func_def.typePars)))
    
    selector_def = replace_field(
        func_def,
        name = :($Virtual.unsafe_dispatch),
        pars = ParamInfo[
            ParamInfo(name = :_, type = sig)
        ],
        typePars = TypeParamInfo[],
        body = Expr(:block, __source__, __source__, :($typeof($impl_name)))
    )
    func_def.name = impl_name
    # func_def.pars = ParamInfo[replace_field(par, meta=[:nospecialize]) for par in func_def.pars]
    
    Expr(:block,
        to_expr(func_def),
        to_expr(new_func_def),
        to_expr(selector_def),
        to_expr(edge_def))
end

function _mk_override(__module__ :: Module, __source__ :: LineNumberNode, @nospecialize(func_def)) 
    func_def.name isa Undefined && throw(create_exception(__source__, "virtual function must have a name"))    
    isempty(func_def.kwPars) || throw(create_exception(__source__, "virtual function does not take keyword parameters"))
    any(par.isVariadic for par in func_def.pars) && throw(create_exception(__source__, "virtual function does not take variadic parameters"))
    argtypes = [ _find_type(par.type) for par in func_def.pars ]
    edge_def = replace_field(
        func_def,
        ln = __source__,
        name = :($Virtual.invoke_virt),
        pars = [
            ParamInfo(name = sym_selected_func, type = :($typeof($(func_def.name)))),
            func_def.pars...
        ],
        body = Expr(:block, __source__, __source__, :nothing))
    
    impl_name = gensym()
    sig = Expr(:curly, Type,
        _mk_where(Expr(:curly, Tuple, :($typeof($(func_def.name))), argtypes...), to_expr.(func_def.typePars)))
    
    selector_def = replace_field(
        func_def,
        name = :($Virtual.unsafe_dispatch),
        pars = ParamInfo[
            ParamInfo(name = :_, type = sig)
        ],
        typePars = TypeParamInfo[],
        body = Expr(:block, __source__, __source__, :($typeof($impl_name)))
    )
    func_def.name = impl_name
    func_def.pars = ParamInfo[replace_field(par, meta=[:nospecialize]) for par in func_def.pars]

    Expr(:block,
        to_expr(func_def),
        to_expr(selector_def),
        to_expr(edge_def))
end

macro virtual(@nospecialize(func_def))
    func_def = macroexpand(__module__, func_def)
    esc(_mk_virtual(__module__, __source__, parse_function(__source__, func_def, allow_short_func=true, allow_lambda=true)))
end

macro override(@nospecialize(func_def))
    func_def = macroexpand(__module__, func_def)
    esc(_mk_override(__module__, __source__, parse_function(__source__, func_def, allow_short_func=true, allow_lambda=true)))
end

end
