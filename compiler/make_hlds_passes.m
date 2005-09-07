%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 1993-2005 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%

:- module hlds__make_hlds__make_hlds_passes.
:- interface.

:- import_module hlds__hlds_module.
:- import_module hlds__hlds_pred.
:- import_module hlds__make_hlds__qual_info.
:- import_module mdbcomp__prim_data.
:- import_module parse_tree__equiv_type.
:- import_module parse_tree__module_qual.
:- import_module parse_tree__prog_data.

:- import_module bool.
:- import_module io.
:- import_module list.
:- import_module term.

    % When adding an item to the HLDS we need to know both its
    % import_status and whether uses of it must be module qualified.
:- type item_status
    ---> item_status(import_status, need_qualifier).

    % do_parse_tree_to_hlds(ParseTree, MQInfo, EqvMap, HLDS, QualInfo,
    %   InvalidTypes, InvalidModes):
    %
    % Given MQInfo (returned by module_qual.m) and EqvMap (returned by
    % equiv_type.m), converts ParseTree to HLDS. Any errors found are
    % recorded in the HLDS num_errors field.
    % Returns InvalidTypes = yes if undefined types found.
    % Returns InvalidModes = yes if undefined or cyclic insts or modes
    % found. QualInfo is an abstract type that is then passed back to
    % produce_instance_method_clauses (see below).
    %
:- pred do_parse_tree_to_hlds(compilation_unit::in, mq_info::in, eqv_map::in,
    module_info::out, qual_info::out, bool::out, bool::out, io::di, io::uo)
    is det.

:- pred add_item_clause(item::in, import_status::in, import_status::out,
    prog_context::in, module_info::in, module_info::out,
    qual_info::in, qual_info::out, io::di, io::uo) is det.

    % If there are any Aditi procedures enable Aditi compilation.
    % If there are only imported Aditi procedures, magic.m still
    % needs to remove the `aditi' and `base_relation' markers
    % so that the procedures are not ignored by the code
    % generation annotation passes (e.g. arg_info.m).
    %
:- pred maybe_enable_aditi_compilation(item_status::in, term__context::in,
    module_info::in, module_info::out, io::di, io::uo) is det.

:- pred add_stratified_pred(string::in, sym_name::in, arity::in,
    term__context::in, module_info::in, module_info::out, io::di, io::uo)
    is det.

    % add_pred_marker(ModuleInfo0, PragmaName, Name, Arity, Status,
    %   Context, Marker, ConflictMarkers, ModuleInfo, !IO):
    %
    % Adds Marker to the marker list of the pred(s) with give Name and Arity,
    % updating the ModuleInfo. If the named pred does not exist, or the pred
    % already has a marker in ConflictMarkers, report an error.
    %
:- pred add_pred_marker(string::in, sym_name::in, arity::in, import_status::in,
    prog_context::in, marker::in, list(marker)::in,
    module_info::in, module_info::out, io::di, io::uo) is det.

:- type add_marker_pred_info == pred(pred_info, pred_info).
:- inst add_marker_pred_info == (pred(in, out) is det).

:- pred do_add_pred_marker(string::in, sym_name::in, arity::in,
    import_status::in, bool::in, term__context::in,
    add_marker_pred_info::in(add_marker_pred_info),
    module_info::in, module_info::out, list(pred_id)::out,
    io::di, io::uo) is det.

:- pred module_mark_as_external(sym_name::in, int::in, prog_context::in,
    module_info::in, module_info::out, io::di, io::uo) is det.

:- pred check_for_errors(pred(module_info, module_info, io, io)
    ::pred(in, out, di, uo) is det, bool::out,
    module_info::in, module_info::out, io::di, io::uo) is det.

:- pred maybe_check_field_access_function(sym_name::in, arity::in,
    import_status::in, prog_context::in, module_info::in,
    io::di, io::uo) is det.

:- implementation.

:- import_module check_hlds__clause_to_proc.
:- import_module check_hlds__type_util.
:- import_module hlds__hlds_data.
:- import_module hlds__hlds_out.
:- import_module hlds__make_hlds__add_class.
:- import_module hlds__make_hlds__add_clause.
:- import_module hlds__make_hlds__add_mode.
:- import_module hlds__make_hlds__add_pragma.
:- import_module hlds__make_hlds__add_pred.
:- import_module hlds__make_hlds__add_solver.
:- import_module hlds__make_hlds__add_special_pred.
:- import_module hlds__make_hlds__add_type.
:- import_module hlds__make_hlds__make_hlds_error.
:- import_module hlds__make_hlds__make_hlds_warn.
:- import_module hlds__make_hlds__qual_info.
:- import_module hlds__special_pred.
:- import_module libs__globals.
:- import_module libs__options.
:- import_module parse_tree__error_util.
:- import_module parse_tree__prog_data.
:- import_module parse_tree__prog_mode.
:- import_module parse_tree__prog_out.
:- import_module parse_tree__prog_type.
:- import_module parse_tree__prog_util.
:- import_module recompilation.

:- import_module int.
:- import_module map.
:- import_module require.
:- import_module set.
:- import_module std_util.
:- import_module string.
:- import_module varset.

do_parse_tree_to_hlds(module(Name, Items), MQInfo0, EqvMap, ModuleInfo,
        QualInfo, InvalidTypes, InvalidModes, !IO) :-
    some [!Module] (
        globals__io_get_globals(Globals, !IO),
        mq_info_get_partial_qualifier_info(MQInfo0, PQInfo),
            module_info_init(Name, Items, Globals, PQInfo, no, !:Module),
            add_item_list_decls_pass_1(Items,
                item_status(local, may_be_unqualified), !Module,
                no, InvalidModes0, !IO),
        globals__io_lookup_bool_option(statistics, Statistics, !IO),
        maybe_report_stats(Statistics, !IO),

        check_for_errors(
            add_item_list_decls_pass_2(Items,
                item_status(local, may_be_unqualified)),
            InvalidTypes1, !Module, !IO),

        % Add constructors and special preds to the HLDS.
        % This must be done after adding all type and
        % `:- pragma foreign_type' declarations.
        % If there were errors in foreign type type declarations,
        % doing this may cause a compiler abort.
        (
            InvalidTypes1 = no,
            module_info_types(!.Module, Types),
            map__foldl3(process_type_defn, Types, no, InvalidTypes2, !Module,
                !IO)
        ;
            InvalidTypes1 = yes,
            InvalidTypes2 = yes
        ),

        % Add the special preds for the builtin types which don't have a
        % type declaration, hence no hlds_type_defn is generated for them.
        (
            Name = mercury_public_builtin_module,
            compiler_generated_rtti_for_builtins(!.Module)
        ->
            varset__init(TVarSet),
            Body = abstract_type(non_solver_type),
            term__context_init(Context),
            Status = local,
            list__foldl(
                (pred(TypeCtor::in, M0::in, M::out) is det :-
                    construct_type(TypeCtor, [], Type),
                    add_special_preds(TVarSet, Type, TypeCtor, Body, Context,
                        Status, M0, M)
                ), builtin_type_ctors_with_no_hlds_type_defn, !Module)
        ;
            true
        ),

        maybe_report_stats(Statistics, !IO),
            % Balance any data structures that need it.
        module_info_optimize(!Module),
        maybe_report_stats(Statistics, !IO),
        init_qual_info(MQInfo0, EqvMap, QualInfo0),
        add_item_list_clauses(Items, local, !Module, QualInfo0, QualInfo, !IO),

        qual_info_get_mq_info(QualInfo, MQInfo),
        mq_info_get_type_error_flag(MQInfo, InvalidTypes3),
        InvalidTypes = InvalidTypes1 `or` InvalidTypes2 `or` InvalidTypes3,
        mq_info_get_mode_error_flag(MQInfo, InvalidModes1),
        InvalidModes = InvalidModes0 `or` InvalidModes1,
        mq_info_get_num_errors(MQInfo, MQ_NumErrors),

        module_info_num_errors(!.Module, ModuleNumErrors),
        NumErrors = ModuleNumErrors + MQ_NumErrors,
        module_info_set_num_errors(NumErrors, !Module),
            % The predid list is constructed in reverse order, for efficiency,
            % so we return it to the correct order here.
        module_info_reverse_predids(!Module),
        ModuleInfo = !.Module
    ).

check_for_errors(P, FoundError, !ModuleInfo, !IO) :-
    io__get_exit_status(BeforeStatus, !IO),
    io__set_exit_status(0, !IO),
    module_info_num_errors(!.ModuleInfo, BeforeNumErrors),
    P(!ModuleInfo, !IO),
    module_info_num_errors(!.ModuleInfo, AfterNumErrors),
    io__get_exit_status(AfterStatus, !IO),
    (
        AfterStatus = 0,
        BeforeNumErrors = AfterNumErrors
    ->
        FoundError = no
    ;
        FoundError = yes
    ),
    ( BeforeStatus \= 0 ->
        io__set_exit_status(BeforeStatus, !IO)
    ;
        true
    ).

%-----------------------------------------------------------------------------%

    % pass 1:
    % Add the declarations one by one to the module,
    % except for type definitions and pragmas.
    %
    % The `InvalidModes' bool records whether we detected
    % any cyclic insts or modes.
    %
:- pred add_item_list_decls_pass_1(item_list::in, item_status::in,
    module_info::in, module_info::out, bool::in, bool::out,
    io::di, io::uo) is det.

add_item_list_decls_pass_1([], _, !ModuleInfo, !InvalidModes, !IO).
add_item_list_decls_pass_1([Item - Context | Items], Status0, !ModuleInfo,
        !InvalidModes, !IO) :-
    add_item_decl_pass_1(Item, Context, Status0, Status1, !ModuleInfo,
        NewInvalidModes, !IO),
    !:InvalidModes = bool__or(!.InvalidModes, NewInvalidModes),
    add_item_list_decls_pass_1(Items, Status1, !ModuleInfo, !InvalidModes, !IO).

    % pass 2:
    % Add the type definitions and pragmas one by one to the module,
    % and add default modes for functions with no mode declaration.
    %
    % Adding type definitions needs to come after we have added the
    % pred declarations,
    % since we need to have the pred_id for `index/2' and `compare/3'
    % when we add compiler-generated clauses for `compare/3'.
    % (And similarly for other compiler-generated predicates like that.)
    %
    % Adding pragmas needs to come after we have added the
    % pred declarations, in order to allow the pragma declarations
    % for a predicate to syntactically precede the pred declaration.
    %
    % Adding default modes for functions needs to come after we have
    % processed all the mode declarations, since otherwise we can't be
    % sure that there isn't a mode declaration for the function.
    %
:- pred add_item_list_decls_pass_2(item_list::in, item_status::in,
    module_info::in, module_info::out, io::di, io::uo) is det.

add_item_list_decls_pass_2([], _, !ModuleInfo, !IO).
add_item_list_decls_pass_2([Item - Context | Items], Status0, !ModuleInfo,
        !IO) :-
    add_item_decl_pass_2(Item, Context, Status0, Status1, !ModuleInfo, !IO),
    add_item_list_decls_pass_2(Items, Status1, !ModuleInfo, !IO).

    % pass 3:
    % Add the clauses one by one to the module.
    % (I supposed this could conceivably be folded into pass 2?)
    %
    % Check that the declarations for field extraction
    % and update functions are sensible.
    %
    % Check that predicates listed in `:- initialise' declarations
    % exist and have the right signature.
    %
:- pred add_item_list_clauses(item_list::in, import_status::in,
    module_info::in, module_info::out, qual_info::in, qual_info::out,
    io::di, io::uo) is det.

add_item_list_clauses([], _Status, !ModuleInfo, !QualInfo, !IO).
add_item_list_clauses([Item - Context | Items], Status0,
        !ModuleInfo, !QualInfo, !IO) :-
    add_item_clause(Item, Status0, Status1, Context, !ModuleInfo, !QualInfo,
        !IO),
    add_item_list_clauses(Items, Status1, !ModuleInfo, !QualInfo, !IO).

%-----------------------------------------------------------------------------%

    % The bool records whether any cyclic insts or modes were
    % detected.
    %
:- pred add_item_decl_pass_1(item::in, prog_context::in,
    item_status::in, item_status::out, module_info::in, module_info::out,
    bool::out, io::di, io::uo) is det.

add_item_decl_pass_1(clause(_, _, _, _, _), _, !Status, !ModuleInfo, no, !IO).
    % Skip clauses.
add_item_decl_pass_1(Item, Context, !Status, !ModuleInfo, no, !IO) :-
    % If this is a solver type then we need to also add the declarations
    % for the compiler generated construction function and deconstruction
    % predicate for the special constrained data constructor.
    %
    % In pass 3 we add the corresponding clauses.
    %
    % Before switch detection, we turn calls to these functions/predicates
    % into ordinary constructions/deconstructions, but preserve the
    % corresponding impurity annotations.
    Item = type_defn(TVarSet, SymName, TypeParams, TypeDefn, _Cond),
    (
        TypeDefn = solver_type(SolverTypeDetails, _MaybeUserEqComp)
    ->
        add_solver_type_decl_items(TVarSet, SymName, TypeParams,
            SolverTypeDetails, Context, !Status, !ModuleInfo, !IO)
    ;
        true
    ).
add_item_decl_pass_1(Item, Context, !Status, !ModuleInfo, InvalidMode, !IO) :-
    Item = inst_defn(VarSet, Name, Params, InstDefn, Cond),
    module_add_inst_defn(VarSet, Name, Params, InstDefn, Cond, Context,
        !.Status, !ModuleInfo, InvalidMode, !IO).
add_item_decl_pass_1(Item, Context, !Status, !ModuleInfo, InvalidMode, !IO) :-
    Item = mode_defn(VarSet, Name, Params, ModeDefn, Cond),
    module_add_mode_defn(VarSet, Name, Params, ModeDefn,
        Cond, Context, !.Status, !ModuleInfo, InvalidMode, !IO).
add_item_decl_pass_1(Item, Context, !Status, !ModuleInfo, no, !IO) :-
    Item = pred_or_func(TypeVarSet, InstVarSet, ExistQVars, PredOrFunc,
        PredName, TypesAndModes, _WithType, _WithInst, MaybeDet, _Cond,
        Purity, ClassContext),
    init_markers(Markers),
    module_add_pred_or_func(TypeVarSet, InstVarSet, ExistQVars, PredOrFunc,
        PredName, TypesAndModes, MaybeDet, Purity, ClassContext, Markers,
        Context, !.Status, _, !ModuleInfo, !IO).
add_item_decl_pass_1(Item, Context, !Status, !ModuleInfo, no, !IO) :-
    Item = pred_or_func_mode(VarSet, MaybePredOrFunc, PredName, Modes,
        _WithInst, MaybeDet, _Cond),
    (
        MaybePredOrFunc = yes(PredOrFunc),
        !.Status = item_status(ImportStatus, _),
        IsClassMethod = no,
        module_add_mode(VarSet, PredName, Modes, MaybeDet, ImportStatus,
            Context, PredOrFunc, IsClassMethod, _, !ModuleInfo, !IO)
    ;
        MaybePredOrFunc = no,
        % equiv_type.m should have either set the pred_or_func
        % or removed the item from the list.
        unexpected(this_file, "add_item_decl_pass_1: " ++
            "no pred_or_func on mode declaration")
    ).
add_item_decl_pass_1(Item, _, !Status, !ModuleInfo, no, !IO) :-
    Item = pragma(_, _).
add_item_decl_pass_1(Item, _, !Status, !ModuleInfo, no, !IO) :-
    Item = promise(_, _, _, _).
add_item_decl_pass_1(Item, Context, !Status, !ModuleInfo, no, !IO) :-
    Item = module_defn(_VarSet, ModuleDefn),
    ( module_defn_update_import_status(ModuleDefn, StatusPrime) ->
        !:Status = StatusPrime
    ; ModuleDefn = import(module(Specifiers)) ->
        !.Status = item_status(IStat, _),
        (
            ( status_defined_in_this_module(IStat, yes)
            ; IStat = imported(ancestor_private_interface)
            )
        ->
            module_add_imported_module_specifiers(Specifiers, !ModuleInfo)
        ;
            module_add_indirectly_imported_module_specifiers(Specifiers,
                !ModuleInfo)
        )
    ; ModuleDefn = use(module(Specifiers)) ->
        !.Status = item_status(IStat, _),
        (
            ( status_defined_in_this_module(IStat, yes)
            ; IStat = imported(ancestor)
            )
        ->
            module_add_imported_module_specifiers(Specifiers, !ModuleInfo)
        ;
            module_add_indirectly_imported_module_specifiers(Specifiers,
                !ModuleInfo)
        )
    ; ModuleDefn = include_module(_) ->
        true
    ; ModuleDefn = external(MaybeBackend, External) ->
        ( External = name_arity(Name, Arity) ->
            lookup_current_backend(CurrentBackend, !IO),
            (
                (
                    MaybeBackend = no
                ;
                    MaybeBackend = yes(Backend),
                    Backend = CurrentBackend
                )
            ->
                module_mark_as_external(Name, Arity, Context, !ModuleInfo, !IO)
            ;
                true
            )
        ;
            prog_out__write_context(Context, !IO),
            report_warning("Warning: `external' declaration requires arity.\n",
                !IO)
        )
    ; ModuleDefn = module(_ModuleName) ->
        report_unexpected_decl("module", Context, !IO)
    ; ModuleDefn = end_module(_ModuleName) ->
        report_unexpected_decl("end_module", Context, !IO)
    ; ModuleDefn = version_numbers(_, _) ->
        true
    ; ModuleDefn = transitively_imported ->
        true
    ;
        prog_out__write_context(Context, !IO),
        report_warning("Warning: declaration not yet implemented.\n", !IO)
    ).
add_item_decl_pass_1(Item, _, !Status, !ModuleInfo, no, !IO) :-
    Item = nothing(_).
add_item_decl_pass_1(Item, Context, !Status, !ModuleInfo, no, !IO) :-
    Item = typeclass(Constraints, FunDeps, Name, Vars, Interface, VarSet),
	module_add_class_defn(Constraints, FunDeps, Name, Vars, Interface,
		VarSet, Context, !.Status, !ModuleInfo, !IO).
add_item_decl_pass_1(Item, _, !Status, !ModuleInfo, no, !IO) :-
    % We add instance declarations on the second pass so that we don't add
    % an instance declaration before its class declaration.
    Item = instance(_, _, _, _, _,_).
add_item_decl_pass_1(Item, _, !Status, !ModuleInfo, no, !IO) :-
    % We add initialise declarations on the second pass.
    Item = initialise(_).
add_item_decl_pass_1(Item, Context, !Status, !ModuleInfo, no, !IO) :-
    % We add the initialise decl and the foreign_decl on the second pass and
    % the foreign_code clauses on the third pass.
    Item = mutable(Name, Type, _InitValue, Inst, _Attrs),
    module_info_name(!.ModuleInfo, ModuleName),
    VarSet = varset__init,
    InstVarSet = varset__init,
    ExistQVars = [],
    Constraints = constraints([], []),
    IOType = term__functor(term__atom("."), [
        term__functor(term__atom("io"), [], Context),
        term__functor(term__atom("state"), [], Context)], Context),
    GetPredDecl = pred_or_func(VarSet, InstVarSet, ExistQVars, predicate,
        mutable_get_pred_sym_name(ModuleName, Name),
        [type_and_mode(Type, out_mode(Inst))],
        no /* with_type */, no /* with_inst */, yes(det),
        true /* condition */, (semipure), Constraints),
    add_item_decl_pass_1(GetPredDecl, Context, !Status, !ModuleInfo, _, !IO),
    SetPredDecl = pred_or_func(VarSet, InstVarSet, ExistQVars, predicate,
        mutable_set_pred_sym_name(ModuleName, Name),
        [type_and_mode(Type, in_mode(Inst))],
        no /* with_type */, no /* with_inst */, yes(det),
        true /* condition */, (impure), Constraints),
    add_item_decl_pass_1(SetPredDecl, Context, !Status, !ModuleInfo, _, !IO),
    InitPredDecl = pred_or_func(VarSet, InstVarSet, ExistQVars, predicate,
        mutable_init_pred_sym_name(ModuleName, Name),
        [type_and_mode(IOType, di_mode), type_and_mode(IOType, uo_mode)],
        no /* with_type */, no /* with_inst */, yes(det),
        true /* condition */, (pure), Constraints),
    add_item_decl_pass_1(InitPredDecl, Context, !Status, !ModuleInfo, _, !IO).

%-----------------------------------------------------------------------------%

:- pred add_item_decl_pass_2(item::in, prog_context::in, item_status::in,
    item_status::out, module_info::in, module_info::out,
    io::di, io::uo) is det.

add_item_decl_pass_2(Item, _Context, !Status, !ModuleInfo, !IO) :-
    Item = module_defn(_VarSet, ModuleDefn),
    ( module_defn_update_import_status(ModuleDefn, StatusPrime) ->
        !:Status = StatusPrime
    ;
        true
    ).
add_item_decl_pass_2(Item, Context, !Status, !ModuleInfo, !IO) :-
    Item = type_defn(VarSet, Name, Args, TypeDefn, Cond),
    module_add_type_defn(VarSet, Name, Args, TypeDefn, Cond, Context,
        !.Status, !ModuleInfo, !IO).
add_item_decl_pass_2(Item, Context, !Status, !ModuleInfo, !IO) :-
    Item = pragma(Origin, Pragma),
    add_pragma(Origin, Pragma, Context, !Status, !ModuleInfo, !IO).
add_item_decl_pass_2(Item, _Context, !Status, !ModuleInfo, !IO) :-
    Item = pred_or_func(_TypeVarSet, _InstVarSet, _ExistQVars,
        PredOrFunc, SymName, TypesAndModes, _WithType, _WithInst,
        _MaybeDet, _Cond, _Purity, _ClassContext),
    %
    % add default modes for function declarations, if necessary
    %
    (
        PredOrFunc = predicate
    ;
        PredOrFunc = function,
        list__length(TypesAndModes, Arity),
        adjust_func_arity(function, FuncArity, Arity),
        module_info_get_predicate_table(!.ModuleInfo, PredTable0),
        (
            predicate_table_search_func_sym_arity(PredTable0,
                is_fully_qualified, SymName, FuncArity, PredIds)
        ->
            predicate_table_get_preds(PredTable0, Preds0),
            maybe_add_default_func_modes(PredIds, Preds0, Preds),
            predicate_table_set_preds(Preds, PredTable0, PredTable),
            module_info_set_predicate_table(PredTable, !ModuleInfo)
        ;
            error("make_hlds_passes.m: can't find func declaration")
        )
    ).
add_item_decl_pass_2(Item, _, !Status, !ModuleInfo, !IO) :-
    Item = promise(_, _, _, _).
add_item_decl_pass_2(Item, _, !Status, !ModuleInfo, !IO) :-
    Item = clause(_, _, _, _, _).
add_item_decl_pass_2(Item, _, !Status, !ModuleInfo, !IO) :-
    Item = inst_defn(_, _, _, _, _).
add_item_decl_pass_2(Item, _, !Status, !ModuleInfo, !IO) :-
    Item = mode_defn(_, _, _, _, _).
add_item_decl_pass_2(Item, _, !Status, !ModuleInfo, !IO) :-
    Item = pred_or_func_mode(_, _, _, _, _, _, _).
add_item_decl_pass_2(Item, _, !Status, !ModuleInfo, !IO) :-
    Item = nothing(_).
add_item_decl_pass_2(Item, _, !Status, !ModuleInfo, !IO) :-
    Item = typeclass(_, _, _, _, _, _).
add_item_decl_pass_2(Item, Context, !Status, !ModuleInfo, !IO) :-
    Item = instance(Constraints, Name, Types, Body, VarSet,
        InstanceModuleName),
    !.Status = item_status(ImportStatus, _),
    ( Body = abstract ->
        make_status_abstract(ImportStatus, BodyStatus)
    ;
        BodyStatus = ImportStatus
    ),
    module_add_instance_defn(InstanceModuleName, Constraints, Name, Types,
        Body, VarSet, BodyStatus, Context, !ModuleInfo, !IO).
add_item_decl_pass_2(Item, Context, !Status, !ModuleInfo, !IO) :-
    Item = initialise(SymName),
    !.Status = item_status(ImportStatus, _),
    ( ImportStatus = exported ->
        error_is_exported(Context, "`initialise' declaration", !IO),
        module_info_incr_errors(!ModuleInfo)
    ;
        true
    ),
    % 
    % To handle a `:- initialise initpred.' declaration we need to
    % (1) construct a new C function name, CName, to use to export initpred,
    % (2) add `:- pragma export(initpred(di, uo), CName).',
    % (3) record the initpred/cname pair in the ModuleInfo so that
    % code generation can ensure cname is called during module
    % initialisation.
    %
    module_info_new_user_init_pred(SymName, CName, !ModuleInfo),
    PragmaExportItem =
        pragma(compiler,
            export(SymName, predicate, [di_mode, uo_mode], CName)),
    add_item_decl_pass_2(PragmaExportItem, Context, !Status, !ModuleInfo, !IO).
add_item_decl_pass_2(Item, Context, !Status, !ModuleInfo, !IO) :-
    Item = mutable(Name, _Type, _InitTerm, _Inst, _MutAttrs),
    module_info_name(!.ModuleInfo, ModuleName),
    InitDecl = initialise(mutable_init_pred_sym_name(ModuleName, Name)),
    add_item_decl_pass_2(InitDecl, Context, !Status, !ModuleInfo, !IO),
    ForeignDecl = pragma(compiler, foreign_decl(c, foreign_decl_is_local,
        "MR_Word " ++ mutable_c_var_name(Name) ++ ";")),
    add_item_decl_pass_2(ForeignDecl, Context, !Status, !ModuleInfo, !IO).


    % XXX We should probably mangle Name for safety...
    %
:- func mutable_get_pred_sym_name(sym_name, string) = sym_name.

mutable_get_pred_sym_name(ModuleName, Name) = 
    qualified(ModuleName, "get_" ++ Name).

:- func mutable_set_pred_sym_name(sym_name, string) = sym_name.

mutable_set_pred_sym_name(ModuleName, Name) = 
    qualified(ModuleName, "set_" ++ Name).

:- func mutable_init_pred_sym_name(sym_name, string) = sym_name.

mutable_init_pred_sym_name(ModuleName, Name) =
    qualified(ModuleName, "initialise_mutable_" ++ Name).

:- func mutable_c_var_name(string) = string.

mutable_c_var_name(Name) = "mutable_variable_" ++ Name.

%-----------------------------------------------------------------------------%

add_item_clause(Item, !Status, Context, !ModuleInfo, !QualInfo, !IO) :-
    Item = clause(VarSet, PredOrFunc, PredName, Args, Body),
    ( !.Status = exported ->
        list.length(Args, Arity),
        %
        % There is no point printing out the qualified name since that
        % information is already in the context.
        %
        unqualify_name(PredName, UnqualifiedPredName),
        ClauseId = simple_call_id_to_string(PredOrFunc,
            unqualified(UnqualifiedPredName) / Arity), 
        error_is_exported(Context, "clause for " ++ ClauseId, !IO),
        module_info_incr_errors(!ModuleInfo)
    ;
        true
    ),
    GoalType = none,
    % at this stage we only need know that it's not a promise declaration
    module_add_clause(VarSet, PredOrFunc, PredName, Args, Body, !.Status,
        Context, GoalType, !ModuleInfo, !QualInfo, !IO).
add_item_clause(Item, !Status, Context, !ModuleInfo, !QualInfo, !IO) :-
    Item = type_defn(_TVarSet, SymName, TypeParams, TypeDefn, _Cond),
    % If this is a solver type then we need to also add clauses
    % the compiler generated inst cast predicate (the declaration
    % for which was added in pass 1).
    (
        TypeDefn = solver_type(SolverTypeDetails, _MaybeUserEqComp)
    ->
        add_solver_type_clause_items(SymName, TypeParams, SolverTypeDetails,
            !Status, Context, !ModuleInfo, !QualInfo, !IO)
    ;
        true
    ).
add_item_clause(Item, !Status, _, !ModuleInfo, !QualInfo, !IO) :-
    Item = inst_defn(_, _, _, _, _).
add_item_clause(Item, !Status, _, !ModuleInfo, !QualInfo, !IO) :-
    Item = mode_defn(_, _, _, _, _).
add_item_clause(Item, !Status, Context, !ModuleInfo, !QualInfo, !IO) :-
    Item = pred_or_func(_, _, _, PredOrFunc, SymName, TypesAndModes,
        _WithType, _WithInst, _, _, _, _),
    (
        PredOrFunc = predicate
    ;
        PredOrFunc = function,
        list__length(TypesAndModes, PredArity),
        adjust_func_arity(function, FuncArity, PredArity),
        maybe_check_field_access_function(SymName, FuncArity, !.Status,
            Context, !.ModuleInfo, !IO)
    ).
add_item_clause(Item, !Status, _, !ModuleInfo, !QualInfo, !IO) :-
    Item = pred_or_func_mode(_, _, _, _, _, _, _).
add_item_clause(Item, !Status, _, !ModuleInfo, !QualInfo, !IO) :-
    Item = module_defn(_, Defn),
    ( Defn = version_numbers(ModuleName, ModuleVersionNumbers) ->
        %
        % Record the version numbers for each imported module
        % if smart recompilation is enabled.
        %
        apply_to_recompilation_info(
            (pred(RecompInfo0::in, RecompInfo::out) is det :-
                RecompInfo = RecompInfo0 ^ version_numbers ^
                    map__elem(ModuleName) := ModuleVersionNumbers
            ),
            !QualInfo)
    ; module_defn_update_import_status(Defn, ItemStatus1) ->
        ItemStatus1 = item_status(!:Status, NeedQual),
        qual_info_get_mq_info(!.QualInfo, MQInfo0),
        mq_info_set_need_qual_flag(NeedQual, MQInfo0, MQInfo),
        qual_info_set_mq_info(MQInfo, !QualInfo)
    ;
        true
    ).
add_item_clause(Item, !Status, Context, !ModuleInfo, !QualInfo, !IO) :-
    Item = pragma(Origin, Pragma),
    (
        Pragma = foreign_proc(Attributes, Pred, PredOrFunc,
            Vars, VarSet, PragmaImpl)
    ->
        module_add_pragma_foreign_proc(Attributes, Pred, PredOrFunc,
            Vars, VarSet, PragmaImpl, !.Status, Context,
            !ModuleInfo, !QualInfo, !IO)
    ;
        Pragma = import(Name, PredOrFunc, Modes, Attributes, C_Function)
    ->
        module_add_pragma_import(Name, PredOrFunc, Modes, Attributes,
            C_Function, !.Status, Context, !ModuleInfo, !QualInfo, !IO)
    ;
        Pragma = fact_table(Pred, Arity, File)
    ->
        module_add_pragma_fact_table(Pred, Arity, File, !.Status,
            Context, !ModuleInfo, !QualInfo, !IO)
    ;
        Pragma = tabled(Type, Name, Arity, PredOrFunc, Mode)
    ->
        globals__io_lookup_bool_option(type_layout, TypeLayout, !IO),
        (
            TypeLayout = yes,
            module_add_pragma_tabled(Type, Name, Arity, PredOrFunc,
                Mode, !.Status, Context, !ModuleInfo, !IO)
        ;
            TypeLayout = no,
            module_info_incr_errors(!ModuleInfo),
            prog_out__write_context(Context, !IO),
            io__write_string("Error: `:- pragma ", !IO),
            EvalMethodS = eval_method_to_one_string(Type),
            io__write_string(EvalMethodS, !IO),
            io__write_string("' declaration requires the type_ctor_layout\n",
                !IO),
            prog_out__write_context(Context, !IO),
            io__write_string("    structures. Use " ++
                "the --type-layout flag to enable them.\n", !IO)
        )
    ;
        Pragma = type_spec(_, _, _, _, _, _, _, _)
    ->
        %
        % XXX For the Java back-end, `pragma type_spec' can
        % result in class names that exceed the limits on file
        % name length.  So we ignore these pragmas for the
        % Java back-end.
        %
        globals__io_get_target(Target, !IO),
        ( Target = java ->
            true
        ;
            add_pragma_type_spec(Pragma, Context, !ModuleInfo, !QualInfo, !IO)
        )
    ;
        Pragma = termination_info(PredOrFunc, SymName, ModeList,
            MaybeArgSizeInfo, MaybeTerminationInfo)
    ->
        add_pragma_termination_info(PredOrFunc, SymName, ModeList,
            MaybeArgSizeInfo, MaybeTerminationInfo, Context,
            !ModuleInfo, !IO)
    ;
        Pragma = termination2_info(PredOrFunc, SymName, ModeList,
            MaybeSuccessArgSizeInfo, MaybeFailureArgSizeInfo,
            MaybeTerminationInfo)
    ->
        add_pragma_termination2_info(PredOrFunc, SymName, ModeList,
            MaybeSuccessArgSizeInfo, MaybeFailureArgSizeInfo,
            MaybeTerminationInfo, Context, !ModuleInfo, !IO)
    ;
        Pragma = reserve_tag(TypeName, TypeArity)
    ->
        add_pragma_reserve_tag(TypeName, TypeArity, !.Status,
            Context, !ModuleInfo, !IO)
    ;
        Pragma = export(Name, PredOrFunc, Modes, C_Function)
    ->
        add_pragma_export(Origin, Name, PredOrFunc, Modes, C_Function,
            Context, !ModuleInfo, !IO)
    ;
        % Don't worry about any pragma declarations other than the
        % clause-like pragmas (c_code, tabling and fact_table),
        % foreign_type and the termination_info pragma here,
        % since they've already been handled earlier, in pass 2.
        true
    ).
add_item_clause(promise(PromiseType, Goal, VarSet, UnivVars),
        !Status, Context, !ModuleInfo, !QualInfo, !IO) :-
    %
    % If the outermost universally quantified variables
    % are placed in the head of the dummy predicate, the
    % typechecker will avoid warning about unbound
    % type variables as this implicity adds a universal
    % quantification of the typevariables needed.
    %
    term__var_list_to_term_list(UnivVars, HeadVars),

    % extra error checking for promise ex declarations
    ( PromiseType \= true ->
        check_promise_ex_decl(UnivVars, PromiseType, Goal, Context, !IO)
    ;
        true
    ),
    % add as dummy predicate
    add_promise_clause(PromiseType, HeadVars, VarSet, Goal, Context,
        !.Status, !ModuleInfo, !QualInfo, !IO).
add_item_clause(nothing(_), !Status, _, !ModuleInfo, !QualInfo, !IO).
add_item_clause(typeclass(_, _, _, _, _, _), !Status, _, !ModuleInfo,
        !QualInfo, !IO).
add_item_clause(instance(_, _, _, _, _, _), !Status, _, !ModuleInfo, !QualInfo,
        !IO).
add_item_clause(initialise(SymName), !Status, Context, !ModuleInfo, !QualInfo,
        !IO) :-
    module_info_get_predicate_table(!.ModuleInfo, PredTable),
    (
        predicate_table_search_pred_sym_arity(PredTable,
            may_be_partially_qualified, SymName, 2 /* Arity */, PredIds)
    ->
        (
            PredIds = [PredId]
        ->
            module_info_pred_info(!.ModuleInfo, PredId, PredInfo),
            pred_info_arg_types(PredInfo, ArgTypes),
            pred_info_procedures(PredInfo, ProcTable),
            ProcInfos = map.values(ProcTable),
            (
                ArgTypes = [Arg1Type, Arg2Type],
                type_util__type_is_io_state(Arg1Type),
                type_util__type_is_io_state(Arg2Type),
                list.member(ProcInfo, ProcInfos),
                proc_info_maybe_declared_argmodes(ProcInfo, MaybeHeadModes),
                MaybeHeadModes = yes(HeadModes),
                HeadModes = [ di_mode, uo_mode ],
                proc_info_declared_determinism(ProcInfo, MaybeDetism),
                MaybeDetism = yes(Detism),
                ( Detism = det ; Detism = cc_multidet )
            ->
                module_info_user_init_pred_c_name(!.ModuleInfo, SymName,
                    CName),
                PragmaExportItem =
                    pragma(compiler,
                        export(SymName, predicate, [di_mode, uo_mode], CName)),
                add_item_clause(PragmaExportItem, !Status, Context,
                    !ModuleInfo, !QualInfo, !IO)
            ;
                write_error_pieces(Context, 0, [words("Error:"),
                    sym_name_and_arity(SymName/2),
                    words(" used in initialise declaration does not have " ++
                    "signature `pred(io::di, io::uo) is det'")], !IO),
                module_info_incr_errors(!ModuleInfo)
            )
        ;
            write_error_pieces(Context, 0, [words("Error:"),
                sym_name_and_arity(SymName/2),
                words(" used in initialise declaration has " ++
                "multiple pred declarations.")], !IO),
            module_info_incr_errors(!ModuleInfo)
        )
    ;
        write_error_pieces(Context, 0, [words("Error:"),
            sym_name_and_arity(SymName/2),
            words(" used in initialise declaration does " ++
            "not have a corresponding pred declaration.")], !IO),
        module_info_incr_errors(!ModuleInfo)
    ).
add_item_clause(Item, !Status, Context, !ModuleInfo, !QualInfo, !IO) :-
    Item = mutable(Name, _Type, InitTerm, Inst, MutAttrs),
    module_info_name(!.ModuleInfo, ModuleName),
    varset__new_named_var(varset__init, "X", X, VarSet),
    Attrs0 = default_attributes(c),
    set_may_call_mercury(will_not_call_mercury, Attrs0, Attrs1),
    (
        list__member(thread_safe, MutAttrs)
    ->
        set_thread_safe(thread_safe, Attrs1, Attrs)
    ;
        Attrs = Attrs1
    ),
    add_item_clause(initialise(mutable_init_pred_sym_name(ModuleName, Name)),
        !Status, Context, !ModuleInfo, !QualInfo, !IO),
    InitClause = clause(VarSet, predicate,
        mutable_init_pred_sym_name(ModuleName, Name),
        [term__variable(X), term__variable(X)],
        promise_purity(dont_make_implicit_promises, (pure),
            call(mutable_set_pred_sym_name(ModuleName, Name),
            [InitTerm], (impure)) - Context
        ) - Context),
    add_item_clause(InitClause, !Status, Context, !ModuleInfo, !QualInfo, !IO),
    set_purity((semipure), Attrs, GetAttrs),
    GetClause = pragma(compiler, foreign_proc(GetAttrs,
        mutable_get_pred_sym_name(ModuleName, Name), predicate,
        [pragma_var(X, "X", out_mode(Inst))], VarSet,
        ordinary("X = " ++ mutable_c_var_name(Name) ++ ";",
            yes(Context)))),
    add_item_clause(GetClause, !Status, Context, !ModuleInfo, !QualInfo, !IO),
    (
        list__member(untrailed, MutAttrs)
    ->
        TrailCode = ""
    ;
        TrailCode =
            "MR_trail_current_value(&" ++ mutable_c_var_name(Name) ++ ");\n"
    ),
    SetClause = pragma(compiler, foreign_proc(Attrs,
        mutable_set_pred_sym_name(ModuleName, Name), predicate,
        [pragma_var(X, "X", in_mode(Inst))], VarSet,
        ordinary(TrailCode ++ mutable_c_var_name(Name) ++ " = X;",
            yes(Context)))),
    add_item_clause(SetClause, !Status, Context, !ModuleInfo, !QualInfo, !IO).


    % If a module_defn updates the import_status, return the new status
    % and whether uses of the following items must be module qualified,
    % otherwise fail.
    %
:- pred module_defn_update_import_status(module_defn::in, item_status::out)
    is semidet.

module_defn_update_import_status(interface,
        item_status(exported, may_be_unqualified)).
module_defn_update_import_status(implementation,
        item_status(local, may_be_unqualified)).
module_defn_update_import_status(private_interface,
        item_status(exported_to_submodules, may_be_unqualified)).
module_defn_update_import_status(imported(Section),
        item_status(imported(Section), may_be_unqualified)).
module_defn_update_import_status(used(Section),
        item_status(imported(Section), must_be_qualified)).
module_defn_update_import_status(opt_imported,
        item_status(opt_imported, must_be_qualified)).
module_defn_update_import_status(abstract_imported,
        item_status(abstract_imported, must_be_qualified)).

%-----------------------------------------------------------------------------%

maybe_enable_aditi_compilation(_Status, Context, !ModuleInfo, !IO) :-
    globals__io_lookup_bool_option(aditi, Aditi, !IO),
    (
        Aditi = no,
        prog_out__write_context(Context, !IO),
        io__write_string("Error: compilation of Aditi procedures\n", !IO),
        prog_out__write_context(Context, !IO),
        io__write_string("  requires the `--aditi' option.\n", !IO),
        io__set_exit_status(1, !IO),
        module_info_incr_errors(!ModuleInfo)
    ;
        Aditi = yes,
        % There are Aditi procedures - enable Aditi code generation.
        module_info_set_do_aditi_compilation(!ModuleInfo)
    ).

:- pred add_promise_clause(promise_type::in, list(term(prog_var_type))::in,
    prog_varset::in, goal::in, prog_context::in, import_status::in,
    module_info::in, module_info::out, qual_info::in, qual_info::out,
    io::di, io::uo) is det.

add_promise_clause(PromiseType, HeadVars, VarSet, Goal, Context, Status,
        !ModuleInfo, !QualInfo, !IO) :-
    term__context_line(Context, Line),
    term__context_file(Context, File),
    string__format(prog_out__promise_to_string(PromiseType) ++
        "__%d__%s", [i(Line), s(File)], Name),
        %
        % Promise declarations are recorded as a predicate with a
        % goal_type of promise(X), where X is of promise_type. This
        % allows us to leverage off all the other checks in the
        % compiler that operate on predicates.
        %
        % :- promise all [A,B,R] ( R = A + B <=> R = B + A ).
        %
        % becomes
        %
        % promise__lineno_filename(A, B, R) :-
        %   ( R = A + B <=> R = B + A ).
        %
    GoalType = promise(PromiseType) ,
    module_info_name(!.ModuleInfo, ModuleName),
    module_add_clause(VarSet, predicate, qualified(ModuleName, Name),
        HeadVars, Goal, Status, Context, GoalType, !ModuleInfo, !QualInfo, !IO).

add_stratified_pred(PragmaName, Name, Arity, Context, !ModuleInfo, !IO) :-
    module_info_get_predicate_table(!.ModuleInfo, PredTable0),
    (
        predicate_table_search_sym_arity(PredTable0, is_fully_qualified,
            Name, Arity, PredIds)
    ->
        module_info_stratified_preds(!.ModuleInfo, StratPredIds0),
        set__insert_list(StratPredIds0, PredIds, StratPredIds),
        module_info_set_stratified_preds(StratPredIds, !ModuleInfo)
    ;
        string__append_list(["`:- pragma ", PragmaName, "' declaration"],
            Description),
        undefined_pred_or_func_error(Name, Arity, Context, Description, !IO),
        module_info_incr_errors(!ModuleInfo)
    ).

%-----------------------------------------------------------------------------%

add_pred_marker(PragmaName, Name, Arity, Status, Context, Marker,
        ConflictMarkers, !ModuleInfo, !IO) :-
    ( marker_must_be_exported(Marker) ->
        MustBeExported = yes
    ;
        MustBeExported = no
    ),
    do_add_pred_marker(PragmaName, Name, Arity, Status, MustBeExported,
        Context, add_marker_pred_info(Marker), !ModuleInfo, PredIds, !IO),
    module_info_preds(!.ModuleInfo, Preds),
    pragma_check_markers(Preds, PredIds, ConflictMarkers, Conflict),
    (
        Conflict = yes,
        pragma_conflict_error(Name, Arity, Context, PragmaName, !IO),
        module_info_incr_errors(!ModuleInfo)
    ;
        Conflict = no
    ).

do_add_pred_marker(PragmaName, Name, Arity, Status, MustBeExported, Context,
        UpdatePredInfo, !ModuleInfo, PredIds, !IO) :-
    ( get_matching_pred_ids(!.ModuleInfo, Name, Arity, PredIds0) ->
        PredIds = PredIds0,
        module_info_get_predicate_table(!.ModuleInfo, PredTable0),
        predicate_table_get_preds(PredTable0, Preds0),

        pragma_add_marker(PredIds, UpdatePredInfo, Status,
            MustBeExported, Preds0, Preds, WrongStatus),
        (
            WrongStatus = yes,
            pragma_status_error(Name, Arity, Context, PragmaName,
                !IO),
            module_info_incr_errors(!ModuleInfo)
        ;
            WrongStatus = no
        ),

        predicate_table_set_preds(Preds, PredTable0, PredTable),
        module_info_set_predicate_table(PredTable, !ModuleInfo)
    ;
        PredIds = [],
        string__append_list(["`:- pragma ", PragmaName, "' declaration"],
            Description),
        undefined_pred_or_func_error(Name, Arity, Context, Description, !IO),
        module_info_incr_errors(!ModuleInfo)
    ).

:- pred get_matching_pred_ids(module_info::in, sym_name::in, arity::in,
    list(pred_id)::out) is semidet.

get_matching_pred_ids(Module0, Name, Arity, PredIds) :-
    module_info_get_predicate_table(Module0, PredTable0),
    % check that the pragma is module qualified.
    (
        Name = unqualified(_),
        error("get_matching_pred_ids: unqualified name")
    ;
        Name = qualified(_, _),
        predicate_table_search_sym_arity(PredTable0, is_fully_qualified,
            Name, Arity, PredIds)
    ).

module_mark_as_external(PredName, Arity, Context, !ModuleInfo, !IO) :-
    % `external' declarations can only apply to things defined
    % in this module, since everything else is already external.
    module_info_get_predicate_table(!.ModuleInfo, PredicateTable0),
    (
        predicate_table_search_sym_arity(PredicateTable0, is_fully_qualified,
            PredName, Arity, PredIdList)
    ->
        module_mark_preds_as_external(PredIdList, !ModuleInfo)
    ;
        undefined_pred_or_func_error(PredName, Arity, Context,
            "`:- external' declaration", !IO),
        module_info_incr_errors(!ModuleInfo)
    ).

:- pred module_mark_preds_as_external(list(pred_id)::in,
    module_info::in, module_info::out) is det.

module_mark_preds_as_external([], !ModuleInfo).
module_mark_preds_as_external([PredId | PredIds], !ModuleInfo) :-
    module_info_preds(!.ModuleInfo, Preds0),
    map__lookup(Preds0, PredId, PredInfo0),
    pred_info_mark_as_external(PredInfo0, PredInfo),
    map__det_update(Preds0, PredId, PredInfo, Preds),
    module_info_set_preds(Preds, !ModuleInfo),
    module_mark_preds_as_external(PredIds, !ModuleInfo).

    % For each pred_id in the list, check whether markers present in the list
    % of conflicting markers are also present in the corresponding pred_info.
    % The bool indicates whether there was a conflicting marker present.
    %
:- pred pragma_check_markers(pred_table::in, list(pred_id)::in,
    list(marker)::in, bool::out) is det.

pragma_check_markers(_, [], _, no).
pragma_check_markers(PredTable, [PredId | PredIds], ConflictList,
        WasConflict) :-
    map__lookup(PredTable, PredId, PredInfo),
    pred_info_get_markers(PredInfo, Markers),
    (
        list__member(Marker, ConflictList),
        check_marker(Markers, Marker)
    ->
        WasConflict = yes
    ;
        pragma_check_markers(PredTable, PredIds, ConflictList, WasConflict)
    ).

    % For each pred_id in the list, add the given markers to the
    % list of markers in the corresponding pred_info.
    %
:- pred pragma_add_marker(list(pred_id)::in,
    add_marker_pred_info::in(add_marker_pred_info), import_status::in,
    bool::in, pred_table::in, pred_table::out, bool::out) is det.

pragma_add_marker([], _, _, _, !PredTable, no).
pragma_add_marker([PredId | PredIds], UpdatePredInfo, Status, MustBeExported,
        !PredTable, WrongStatus) :-
    map__lookup(!.PredTable, PredId, PredInfo0),
    call(UpdatePredInfo, PredInfo0, PredInfo),
    (
        pred_info_is_exported(PredInfo),
        MustBeExported = yes,
        Status \= exported
    ->
        WrongStatus0 = yes
    ;
        WrongStatus0 = no
    ),
    map__det_update(!.PredTable, PredId, PredInfo, !:PredTable),
    pragma_add_marker(PredIds, UpdatePredInfo, Status,
        MustBeExported, !PredTable, WrongStatus1),
    bool__or(WrongStatus0, WrongStatus1, WrongStatus).

:- pred add_marker_pred_info(marker::in, pred_info::in, pred_info::out)
    is det.

add_marker_pred_info(Marker, !PredInfo) :-
    pred_info_get_markers(!.PredInfo, Markers0),
    add_marker(Marker, Markers0, Markers),
    pred_info_set_markers(Markers, !PredInfo).

    % Succeed if a marker for an exported procedure must also be exported.
    %
:- pred marker_must_be_exported(marker::in) is semidet.

marker_must_be_exported(aditi).
marker_must_be_exported(base_relation).

maybe_check_field_access_function(FuncName, FuncArity, Status, Context,
        Module, !IO) :-
    (
        is_field_access_function_name(Module, FuncName, FuncArity,
            AccessType, FieldName)
    ->
        check_field_access_function(AccessType, FieldName, FuncName,
            FuncArity, Status, Context, Module, !IO)
    ;
        true
    ).

:- pred check_field_access_function(field_access_type::in, ctor_field_name::in,
    sym_name::in, arity::in, import_status::in, prog_context::in,
    module_info::in, io::di, io::uo) is det.

check_field_access_function(_AccessType, FieldName, FuncName, FuncArity,
        FuncStatus, Context, Module, !IO) :-
    adjust_func_arity(function, FuncArity, PredArity),
    FuncCallId = function - FuncName/PredArity,

    %
    % Check that a function applied to an exported type
    % is also exported.
    %
    module_info_ctor_field_table(Module, CtorFieldTable),
    (
        % Abstract types have status `abstract_exported',
        % so errors won't be reported for local field
        % access functions for them.
        map__search(CtorFieldTable, FieldName, [FieldDefn]),
        FieldDefn = hlds_ctor_field_defn(_, DefnStatus, _, _, _),
        DefnStatus = exported, FuncStatus \= exported
    ->
        report_field_status_mismatch(Context, FuncCallId, !IO)
    ;
        true
    ).

%-----------------------------------------------------------------------------%

:- pred report_field_status_mismatch(prog_context::in, simple_call_id::in,
    io::di, io::uo) is det.

report_field_status_mismatch(Context, CallId, !IO) :-
    ErrorPieces = [
        words("In declaration of"), simple_call_id(CallId), suffix(":"), nl,
        words("error: a field access function for an"),
        words("exported field must also be exported.")
    ],
    error_util__write_error_pieces(Context, 0, ErrorPieces, !IO),
    io__set_exit_status(1, !IO).

:- pred report_unexpected_decl(string::in, prog_context::in,
    io::di, io::uo) is det.

report_unexpected_decl(Descr, Context, !IO) :-
    Pieces = [words("Error: unexpected or incorrect"),
        words("`" ++ Descr ++ "' declaration.")],
    write_error_pieces(Context, 0, Pieces, !IO),
    io__set_exit_status(1, !IO).

:- pred pragma_status_error(sym_name::in, int::in, prog_context::in,
    string::in, io::di, io::uo) is det.

pragma_status_error(Name, Arity, Context, PragmaName, !IO) :-
    Pieces = [words("Error: `:- pragma " ++ PragmaName ++ "'"),
        words("declaration for exported predicate or function"),
        sym_name_and_arity(Name / Arity),
        words("must also be exported.")],
    write_error_pieces(Context, 0, Pieces, !IO),
    io__set_exit_status(1, !IO).

:- pred pragma_conflict_error(sym_name::in, int::in, prog_context::in,
    string::in, io::di, io::uo) is det.

pragma_conflict_error(Name, Arity, Context, PragmaName, !IO) :-
    Pieces = [words("Error: `:- pragma " ++ PragmaName ++ "'"),
        words("declaration conflicts with previous pragma for"),
        sym_name_and_arity(Name / Arity), suffix(".")],
    write_error_pieces(Context, 0, Pieces, !IO),
    io__set_exit_status(1, !IO).

:- func this_file = string.

this_file = "make_hlds_passes.m".

%-----------------------------------------------------------------------------%