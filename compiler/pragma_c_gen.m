%---------------------------------------------------------------------------%
% Copyright (C) 1996-2005 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% File: pragma_c_gen.m
%
% Main authors: dgj, conway, zs.
%
% The code in this module generates code for pragma_c_code goals.
%
% The schemes we use to generate code for model_det and model_semi
% pragma_c_codes are quite similar, so we handle them together.
% The code that does this is reasonably simple.
%
% The scheme for model_non pragma_c_codes is substantially different,
% so we handle them separately.

:- module ll_backend__pragma_c_gen.

:- interface.

:- import_module hlds__code_model.
:- import_module hlds__hlds_goal.
:- import_module hlds__hlds_pred.
:- import_module ll_backend__code_info.
:- import_module ll_backend__llds.
:- import_module mdbcomp__prim_data.
:- import_module parse_tree__prog_data.

:- import_module list.

:- pred pragma_c_gen__generate_pragma_c_code(code_model::in,
	pragma_foreign_proc_attributes::in, pred_id::in, proc_id::in,
	list(foreign_arg)::in, list(foreign_arg)::in, hlds_goal_info::in,
	pragma_foreign_code_impl::in, code_tree::out,
	code_info::in, code_info::out) is det.

:- pred pragma_c_gen__struct_name(module_name::in, string::in, int::in,
	proc_id::in, string::out) is det.

	% The name of the variable model_semi foreign_procs in C assign to
	% to indicate success or failure. Exported for llds_out.m.
	%
:- func pragma_succ_ind_name = string.

%---------------------------------------------------------------------------%

:- implementation.

:- import_module backend_libs__c_util.
:- import_module backend_libs__foreign.
:- import_module backend_libs__name_mangle.
:- import_module check_hlds__mode_util.
:- import_module check_hlds__type_util.
:- import_module hlds__hlds_data.
:- import_module hlds__hlds_llds.
:- import_module hlds__hlds_module.
:- import_module hlds__hlds_pred.
:- import_module hlds__instmap.
:- import_module libs__globals.
:- import_module libs__options.
:- import_module libs__tree.
:- import_module ll_backend__code_util.
:- import_module ll_backend__llds_out.
:- import_module ll_backend__trace.
:- import_module parse_tree__error_util.
:- import_module parse_tree__prog_foreign.
:- import_module parse_tree__prog_type.

:- import_module assoc_list.
:- import_module bool.
:- import_module int.
:- import_module map.
:- import_module require.
:- import_module set.
:- import_module std_util.
:- import_module string.
:- import_module term.

% The code we generate for an ordinary (model_det or model_semi) pragma_c_code
% must be able to fit into the middle of a procedure, since such
% pragma_c_codes can be inlined. This code is of the following form:
%
%    <save live variables onto the stack> /* see note (1) below */
%    {
%	<declaration of one local variable for each arg>
%	#define MR_PROC_LABEL <procedure label> /* see note (5) below */
%
%	<assignment of input values from registers to local variables>
%	MR_save_registers(); /* see notes (1) and (2) below */
%	{ <the c code itself> }
%	<for semidet code, check of r1>
%	#ifndef MR_CONSERVATIVE_GC
%	  MR_restore_registers(); /* see notes (1) and (3) below */
%	#endif
%	<assignment of the output values from local variables to registers>
%
%	#undef MR_PROC_LABEL /* see note (5) below */
%    }
%
% In the case of a semidet pragma c_code, the above is followed by
%
%    goto skip_label;
%    fail_label:
%    <code to fail>
%    skip_label:
%
% and the <check of r1> is of the form
%
%	if (!r1) MR_GOTO_LABEL(fail_label);
%
% In the case of a pragma c_code with determinism failure, the above
% is followed by
%
%    <code to fail>
%
% and the <check of r1> is empty.
%
% The code we generate for nondet pragma_c_code assumes that this code is
% the only thing between the procedure prolog and epilog; such pragma_c_codes
% therefore cannot be inlined. The code of the procedure is of one of the
% following two forms:
%
% form 1 (duplicated common code):
% <proc entry label and comments>
% <mkframe including space for the save struct, redoip = do_fail>
% <#define MR_ORDINARY_SLOTS>
% <--- boundary between prolog and code generated here --->
% <set redoip to point to &&xxx_i1>
% <code for entry to a disjunction and first disjunct>
% {
%	<declaration of one local variable for each input and output arg>
%	<declaration of one local variable to point to save struct>
%	<assignment of input values from registers to local variables>
%	<assignment to save struct pointer>
%	MR_save_registers(); /* see notes (1) and (2) below */
%	#define MR_PROC_LABEL <procedure label> /* see note (5) below */
%	#define SUCCEED()	goto callsuccesslabel
%	#define SUCCEED_LAST()	goto calllastsuccesslabel
%	#define FAIL()		fail()
%	{ <the user-written call c code> }
%	{ <the user-written shared c code> }
% callsuccesslabel:
%	MR_restore_registers(); /* see notes (1) and (3) below */
%	<assignment of the output values from local variables to registers>
%	succeed()
% calllastsuccesslabel: /* see note (4) below) */
%	MR_restore_registers(); /* see notes (1) and (3) below */
%	<assignment of the output values from local variables to registers>
%	succeed_discard()
% 	#undef SUCCEED
% 	#undef SUCCEED_LAST
% 	#undef FAIL
%	#undef MR_PROC_LABEL /* see note (5) below */
% }
% MR_define_label(xxx_i1)
% <code for entry to a later disjunct>
% {
%	<declaration of one local variable for each output arg>
%	<declaration of one local variable to point to save struct>
%	<assignment to save struct pointer>
%	MR_save_registers(); /* see notes (1) and (2) below */
%	#define MR_PROC_LABEL <procedure label> /* see note (5) below */
%	#define SUCCEED()	goto retrysuccesslabel
%	#define SUCCEED_LAST()	goto retrylastsuccesslabel
%	#define FAIL()		fail()
%	{ <the user-written retry c code> }
%	{ <the user-written shared c code> }
% retrysuccesslabel:
%	MR_restore_registers(); /* see notes (1) and (3) below */
%	<assignment of the output values from local variables to registers>
%	succeed()
% retrylastsuccesslabel: /* see note (4) below) */
%	MR_restore_registers(); /* see notes (1) and (3) below */
%	<assignment of the output values from local variables to registers>
%	succeed_discard()
% 	#undef SUCCEED
% 	#undef SUCCEED_LAST
% 	#undef FAIL
%	#undef MR_PROC_LABEL /* see note (5) below */
% }
% <--- boundary between code generated here and epilog --->
% <#undef MR_ORDINARY_SLOTS>
%
% form 2 (shared common code):
% <proc entry label and comments>
% <mkframe including space for the save struct, redoip = do_fail>
% <#define MR_ORDINARY_SLOTS>
% <--- boundary between prolog and code generated here --->
% <set redoip to point to &&xxx_i1>
% <code for entry to a disjunction and first disjunct>
% {
%	<declaration of one local variable for each input and output arg>
%	<declaration of one local variable to point to save struct>
%	<assignment of input values from registers to local variables>
%	<assignment to save struct pointer>
%	MR_save_registers(); /* see notes (1) and (2) below */
%	#define MR_PROC_LABEL <procedure label> /* see note (5) below */
%	#define SUCCEED()	goto callsuccesslabel
%	#define SUCCEED_LAST()	goto calllastsuccesslabel
%	#define FAIL()		fail()
%	{ <the user-written call c code> }
%	MR_GOTO_LABEL(xxx_i2)
% callsuccesslabel: /* see note (4) below */
%	MR_restore_registers(); /* see notes (1) and (3) below */
%	<assignment of the output values from local variables to registers>
%	succeed()
% calllastsuccesslabel: /* see note (4) below */
%	MR_restore_registers(); /* see notes (1) and (3) below */
%	<assignment of the output values from local variables to registers>
%	succeed_discard()
% 	#undef SUCCEED
% 	#undef SUCCEED_LAST
% 	#undef FAIL
%	#undef MR_PROC_LABEL /* see note (5) below */
% }
% MR_define_label(xxx_i1)
% <code for entry to a later disjunct>
% {
%	<declaration of one local variable for each output arg>
%	<declaration of one local variable to point to save struct>
%	<assignment to save struct pointer>
%	MR_save_registers(); /* see notes (1) and (2) below */
%	#define MR_PROC_LABEL <procedure label> /* see note (5) below */
%	#define SUCCEED()	goto retrysuccesslabel
%	#define SUCCEED_LAST()	goto retrylastsuccesslabel
%	#define FAIL()		fail()
%	{ <the user-written retry c code> }
%	MR_GOTO_LABEL(xxx_i2)
% retrysuccesslabel: /* see note (4) below */
%	MR_restore_registers(); /* see notes (1) and (3) below */
%	<assignment of the output values from local variables to registers>
%	succeed()
% retrylastsuccesslabel: /* see note (4) below */
%	MR_restore_registers(); /* see notes (1) and (3) below */
%	<assignment of the output values from local variables to registers>
%	succeed_discard()
% 	#undef SUCCEED
% 	#undef SUCCEED_LAST
% 	#undef FAIL
%	#undef MR_PROC_LABEL /* see note (5) below */
% }
% MR_define_label(xxx_i2)
% {
%	<declaration of one local variable for each output arg>
%	<declaration of one local variable to point to save struct>
%	<assignment to save struct pointer>
%	#define MR_PROC_LABEL <procedure label> /* see note (5) below */
%	#define SUCCEED()	goto sharedsuccesslabel
%	#define SUCCEED_LAST()	goto sharedlastsuccesslabel
%	#define FAIL()		fail()
%	{ <the user-written shared c code> }
% sharedsuccesslabel:
%	MR_restore_registers(); /* see notes (1) and (3) below */
%	<assignment of the output values from local variables to registers>
%	succeed()
% sharedlastsuccesslabel: /* see note (4) below */
%	MR_restore_registers(); /* see notes (1) and (3) below */
%	<assignment of the output values from local variables to registers>
%	succeed_discard()
% 	#undef SUCCEED
% 	#undef SUCCEED_LAST
% 	#undef FAIL
%	#undef MR_PROC_LABEL /* see note (5) below */
% }
% <--- boundary between code generated here and epilog --->
% <#undef MR_ORDINARY_SLOTS>
%
% The first form is more time efficient, since it does not include the jumps
% from the call code and retry code to the shared code and the following
% initialization of the save struct pointer in the shared code block,
% while the second form can lead to smaller code since it does not include
% the shared C code (which can be quite big) twice.
%
% Programmers may indicate which form they wish the compiler to use;
% if they don't, the compiler will choose form 1 if the shared code fragment
% is "short", and form 2 if it is "long".
%
% The procedure prolog creates a nondet stack frame that includes space for
% a struct that is saved across calls. Since the position of this struct in
% the nondet stack frame is not known until the procedure prolog is created,
% which is *after* the call to pragma_c_gen__generate_pragma_c_code, the
% prolog will #define MR_ORDINARY_SLOTS as the number of ordinary slots
% in the nondet frame. From the size of the fixed portion of the nondet stack
% frame, from MR_ORDINARY_SLOTS and from the size of the save struct itself,
% one can calculate the address of the save struct itself. The epilog will
% #undef MR_ORDINARY_SLOTS. It need not do anything else, since all the normal
% epilog stuff has been done in the code above.
%
% Unlike with ordinary pragma C codes, with nondet C codes there are never
% any live variables to save at the start, except for the input variables,
% and saving these is a job for the included C code. Also unlike ordinary
% pragma C codes, nondet C codes are never followed by any other code,
% so the exprn_info component of the code generator state need not be
% kept up to date.
%
% Depending on the value of options such as generate_trace, use_trail, and
% reclaim_heap_on_nondet_failure, we may need to include some code before
% the call and retry labels. The generation of this code should follow
% the same rules as the generation of similar code in nondet disjunctions.
%
% Notes:
%
% (1)	These parts are only emitted if the C code may call Mercury.
%	If a pragma c_code(will_not_call_mercury, ...) declaration was used,
%	they will not be emitted.
%
% (2)	The call to MR_save_registers() is needed so that if the
%	C code calls Mercury code, we can call MR_restore_registers()
%	on entry to the Mercury code (see export.m) to get the
%	right values of `sp', `hp', `curfr' and `maxfr' for the
%	recursive invocation of Mercury.
%
% (3)	The call to MR_restore_registers() is needed in case the
%	C code calls Mercury code which allocates some data
%	on the heap, and this data is returned from Mercury
%	through C back to Mercury.  In that case, we need to
%	keep the value of `hp' that was set by the recursive
%	invocation of Mercury.  The Mercury calling convention
%	guarantees that when calling det or semidet code, the values
%	of `sp', `curfr', and `maxfr' will be preserved, so if we're
%	using conservative gc, there is nothing that needs restoring.
%
%	When calling nondet code, maxfr may be changed. This is why
%	we must call MR_restore_registers() from the code we generate for
%	nondet pragma C codes even if we are not using conservative gc.
%
% (4)	These labels and the code following them can be optimized away
%	by the C compiler if the macro that branches to them is not invoked
%	in the preceding body of included C code. We cannot optimize them
%	away ourselves, since these macros can be invoked from other macros,
%	and thus we do not have a sure test of whether the code fragments
%	invoke the macros.
%
% (5)	We insert a #define for MR_PROC_LABEL, so that the C code in the
%	Mercury standard library that allocates memory manually can use
%	MR_PROC_LABEL as the procname argument to incr_hp_msg(), for memory
%	profiling.  Hard-coding the procname argument in the C code would
%	be wrong, since it wouldn't handle the case where the original
%	pragma c_code procedure gets inlined and optimized away.
%	Of course we also need to #undef it afterwards.

pragma_c_gen__generate_pragma_c_code(CodeModel, Attributes, PredId, ProcId,
		Args, ExtraArgs, GoalInfo, PragmaImpl, Code, !CI) :-
	(
		PragmaImpl = ordinary(C_Code, Context),
		pragma_c_gen__ordinary_pragma_c_code(CodeModel, Attributes,
			PredId, ProcId, Args, ExtraArgs, C_Code, Context,
			GoalInfo, Code, !CI)
	;
		PragmaImpl = nondet(
			Fields, FieldsContext, First, FirstContext,
			Later, LaterContext, Treat, Shared, SharedContext),
		require(unify(ExtraArgs, []),
			"generate_pragma_c_code: extra args nondet"),
		pragma_c_gen__nondet_pragma_c_code(CodeModel, Attributes,
			PredId, ProcId, Args, Fields, FieldsContext,
			First, FirstContext, Later, LaterContext,
			Treat, Shared, SharedContext, Code, !CI)
	;
		PragmaImpl = import(Name, HandleReturn, Vars, Context),
		require(unify(ExtraArgs, []),
			"generate_pragma_c_code: extra args import"),
		C_Code = string__append_list([HandleReturn, " ",
				Name, "(", Vars, ");"]),
		pragma_c_gen__ordinary_pragma_c_code(CodeModel, Attributes,
			PredId, ProcId, Args, ExtraArgs, C_Code, Context,
			GoalInfo, Code, !CI)
	).

%---------------------------------------------------------------------------%

:- pred pragma_c_gen__ordinary_pragma_c_code(code_model::in,
	pragma_foreign_proc_attributes::in, pred_id::in, proc_id::in,
	list(foreign_arg)::in, list(foreign_arg)::in, string::in,
	maybe(prog_context)::in, hlds_goal_info::in, code_tree::out,
	code_info::in, code_info::out) is det.

pragma_c_gen__ordinary_pragma_c_code(CodeModel, Attributes, PredId, ProcId,
		Args, ExtraArgs, C_Code, Context, GoalInfo, Code, !CI) :-

	%
	% Extract the attributes
	%
	MayCallMercury = may_call_mercury(Attributes),
	ThreadSafe = thread_safe(Attributes),
	%
	% The maybe_thread_safe attribute should have been changed
	% to the real value by now.
	%
	( ThreadSafe = maybe_thread_safe ->
		unexpected(this_file, "ordinary_pragma_c_code/12: " ++
			"maybe_thread_safe encountered.")
	;
		true
	),
	%
	% First we need to get a list of input and output arguments
	%
	ArgInfos = code_info__get_pred_proc_arginfo(!.CI, PredId, ProcId),
	make_c_arg_list(Args, ArgInfos, OrigCArgs),
	code_info__get_module_info(!.CI, ModuleInfo),
	make_extra_c_arg_list(ExtraArgs, ModuleInfo, ArgInfos, ExtraCArgs),
	list__append(OrigCArgs, ExtraCArgs, CArgs),
	pragma_select_in_args(CArgs, InCArgs),
	pragma_select_out_args(CArgs, OutCArgs),

	goal_info_get_post_deaths(GoalInfo, PostDeaths),
	set__init(DeadVars0),
	find_dead_input_vars(InCArgs, PostDeaths, DeadVars0, DeadVars),

	%
	% Generate code to <save live variables on stack>
	%
	(
		MayCallMercury = will_not_call_mercury,
		SaveVarsCode = empty
	;
		MayCallMercury = may_call_mercury,
		% The C code might call back Mercury code
		% which clobbers the succip.
		code_info__succip_is_used(!CI),

		% The C code might call back Mercury code which clobbers the
		% other registers, so we need to save any live variables
		% (other than the output args) onto the stack.
		get_c_arg_list_vars(OutCArgs, OutVars),
		set__list_to_set(OutVars, OutVarsSet),
		code_info__save_variables(OutVarsSet, _, SaveVarsCode, !CI)
	),

	%
	% Generate the values of input variables.
	% (NB we need to be careful that the rvals generated here
	% remain valid below.)
	%
	get_pragma_input_vars(InCArgs, InputDescs, InputVarsCode, !CI),

	%
	% We cannot kill the forward dead input arguments until we have
	% finished generating the code producing the input variables.
	% (The forward dead variables will be dead after the pragma_c_code,
	% but are live during its input phase.)
	code_info__make_vars_forward_dead(DeadVars, !CI),

	%
	% Generate <declaration of one local variable for each arg>
	%
	make_pragma_decls(CArgs, ModuleInfo, Decls),

	%
	% Generate #define MR_PROC_LABEL <procedure label> /* see note (5) */
	% and #undef MR_PROC_LABEL
	%
	code_info__get_pred_id(!.CI, CallerPredId),
	code_info__get_proc_id(!.CI, CallerProcId),
	make_proc_label_hash_define(ModuleInfo, CallerPredId, CallerProcId,
		ProcLabelHashDefine, ProcLabelHashUndef),

	%
	% <assignment of input values from registers to local vars>
	%
	InputComp = pragma_c_inputs(InputDescs),

	%
	% MR_save_registers(); /* see notes (1) and (2) above */
	%
	(
		MayCallMercury = will_not_call_mercury,
		SaveRegsComp = pragma_c_raw_code("",
			live_lvals_info(set__init))
	;
		MayCallMercury = may_call_mercury,
		SaveRegsComp = pragma_c_raw_code(
			"\tMR_save_registers();\n",
			live_lvals_info(set__init))
	),

	%
	% Code fragments to obtain and release the global lock
	%
	(
		ThreadSafe = thread_safe,
		ObtainLock = pragma_c_raw_code("", live_lvals_info(set__init)),
		ReleaseLock = pragma_c_raw_code("", live_lvals_info(set__init))
	;
		ThreadSafe = not_thread_safe,
		module_info_pred_info(ModuleInfo, PredId, PredInfo),
		Name = pred_info_name(PredInfo),
		c_util__quote_string(Name, MangledName),
		string__append_list(["\tMR_OBTAIN_GLOBAL_LOCK(""",
			MangledName, """);\n"], ObtainLockStr),
		ObtainLock = pragma_c_raw_code(ObtainLockStr,
			live_lvals_info(set__init)),
		string__append_list(["\tMR_RELEASE_GLOBAL_LOCK(""",
			MangledName, """);\n"], ReleaseLockStr),
		ReleaseLock = pragma_c_raw_code(ReleaseLockStr,
			live_lvals_info(set__init))
	
	;
		ThreadSafe = maybe_thread_safe,
		unexpected(this_file, "ordinary_pragma_c_code/12: " ++
			"maybe_thread_safe encountered.")
	),

	%
	% <The C code itself>
	%
	C_Code_Comp = pragma_c_user_code(Context, C_Code),

	%
	% <for semidet code, check of SUCCESS_INDICATOR>
	%
	goal_info_get_determinism(GoalInfo, Detism),
	( CodeModel = model_semi ->
		( Detism = failure ->
			CheckSuccess_Comp = pragma_c_noop,
			MaybeFailLabel = no
		;
			code_info__get_next_label(FailLabel, !CI),
			CheckSuccess_Comp = pragma_c_fail_to(FailLabel),
			MaybeFailLabel = yes(FailLabel)
		),
		DefSuccessComp = pragma_c_raw_code(
			"\tMR_bool " ++ pragma_succ_ind_name ++ ";\n" ++
			"#undef SUCCESS_INDICATOR\n" ++
			"#define SUCCESS_INDICATOR MercurySuccessIndicator\n",
			live_lvals_info(set__init)),
		UndefSuccessComp = pragma_c_raw_code(
			"#undef SUCCESS_INDICATOR\n" ++
			"#define SUCCESS_INDICATOR MR_r1\n",
			live_lvals_info(set__init))
	;
		CheckSuccess_Comp = pragma_c_noop,
		MaybeFailLabel = no,
		DefSuccessComp = pragma_c_raw_code("",
			live_lvals_info(set__init)),
		UndefSuccessComp = pragma_c_raw_code("",
			live_lvals_info(set__init))
	),

	%
	% #ifndef MR_CONSERVATIVE_GC
	%   MR_restore_registers(); /* see notes (1) and (3) above */
	% #endif
	%
	(
		MayCallMercury = will_not_call_mercury,
		RestoreRegsComp = pragma_c_noop
	;
		MayCallMercury = may_call_mercury,
		RestoreRegsComp = pragma_c_raw_code(
			"#ifndef MR_CONSERVATIVE_GC\n\t" ++
				"MR_restore_registers();\n#endif\n",
			live_lvals_info(set__init)
		)
	),

	%
	% The C code may have called Mercury code which clobbered the regs,
	% in which case we need to tell the code_info that they have been
	% clobbered.
	%
	(
		MayCallMercury = will_not_call_mercury
	;
		MayCallMercury = may_call_mercury,
		goal_info_get_instmap_delta(GoalInfo, InstMapDelta),
		(instmap_delta_is_reachable(InstMapDelta) ->
			OkToDelete = no
		;
			OkToDelete = yes
		),
		code_info__clear_all_registers(OkToDelete, !CI)
	),

	%
	% <assignment of the output values from local variables to registers>
	%
	pragma_acquire_regs(OutCArgs, Regs, !CI),
	place_pragma_output_args_in_regs(OutCArgs, Regs, OutputDescs, !CI),
	OutputComp = pragma_c_outputs(OutputDescs),

	%
	% join all the components of the pragma_c together
	%
	Components = [ProcLabelHashDefine, DefSuccessComp, InputComp,
		SaveRegsComp, ObtainLock, C_Code_Comp, ReleaseLock,
		CheckSuccess_Comp, RestoreRegsComp,
		OutputComp, UndefSuccessComp, ProcLabelHashUndef],
	(
		ExtraArgs = [],
		MaybeDupl = yes
	;
		ExtraArgs = [_ | _],
		MaybeDupl = no
	),
	PragmaCCode = node([
		pragma_c(Decls, Components, MayCallMercury, no, no, no,
			MaybeFailLabel, no, MaybeDupl)
			- "Pragma C inclusion"
	]),

	%
	% for semidet code, we need to insert the failure handling code here:
	%
	%	goto skip_label;
	%	fail_label:
	%	<code to fail>
	%	skip_label:
	%
	% for code with determinism failure, we need to insert the failure
	% handling code here:
	%
	%	<code to fail>
	%
	( MaybeFailLabel = yes(TheFailLabel) ->
		code_info__get_next_label(SkipLabel, !CI),
		code_info__generate_failure(FailCode, !CI),
		GotoSkipLabelCode = node([
			goto(label(SkipLabel)) - "Skip past failure code"
		]),
		SkipLabelCode = node([label(SkipLabel) - ""]),
		FailLabelCode = node([label(TheFailLabel) - ""]),
		FailureCode = tree_list([GotoSkipLabelCode, FailLabelCode,
			FailCode, SkipLabelCode])
	; Detism = failure ->
		code_info__generate_failure(FailureCode, !CI)
	;
		FailureCode = empty
	),

	%
	% join all code fragments together
	%
	Code = tree_list([SaveVarsCode, InputVarsCode, PragmaCCode,
		FailureCode]).

:- pred make_proc_label_hash_define(module_info::in, pred_id::in, proc_id::in,
	pragma_c_component::out, pragma_c_component::out) is det.

make_proc_label_hash_define(ModuleInfo, PredId, ProcId,
		ProcLabelHashDef, ProcLabelHashUndef) :-
	ProcLabelHashDef = pragma_c_raw_code(string__append_list([
		"#define\tMR_PROC_LABEL\t",
		make_proc_label_string(ModuleInfo, PredId, ProcId), "\n"]),
		live_lvals_info(set__init)),
	ProcLabelHashUndef = pragma_c_raw_code("#undef\tMR_PROC_LABEL\n",
		live_lvals_info(set__init)).

:- func make_proc_label_string(module_info, pred_id, proc_id) = string.

make_proc_label_string(ModuleInfo, PredId, ProcId) = ProcLabelString :-
	code_util__make_entry_label(ModuleInfo, PredId, ProcId, no, CodeAddr),
	( CodeAddr = imported(ProcLabel) ->
		ProcLabelString = proc_label_to_c_string(ProcLabel, yes)
	; CodeAddr = label(Label) ->
		ProcLabelString = label_to_c_string(Label, yes)
	;
		error("unexpected code_addr in make_proc_label_hash_define")
	).

%-----------------------------------------------------------------------------%

:- pred pragma_c_gen__nondet_pragma_c_code(code_model::in,
	pragma_foreign_proc_attributes::in, pred_id::in, proc_id::in,
	list(foreign_arg)::in,
	string::in, maybe(prog_context)::in,
	string::in, maybe(prog_context)::in,
	string::in, maybe(prog_context)::in, pragma_shared_code_treatment::in,
	string::in, maybe(prog_context)::in, code_tree::out,
	code_info::in, code_info::out) is det.

pragma_c_gen__nondet_pragma_c_code(CodeModel, Attributes, PredId, ProcId,
		Args, _Fields, _FieldsContext,
		First, FirstContext, Later, LaterContext, Treat, Shared,
		SharedContext, Code, !CI) :-
	require(unify(CodeModel, model_non),
		"inappropriate code model for nondet pragma C code"),
	%
	% Extract the may_call_mercury attribute
	%
	MayCallMercury = may_call_mercury(Attributes),

	%
	% Generate #define MR_PROC_LABEL <procedure label> /* see note (5) */
	% and #undef MR_PROC_LABEL
	%
	code_info__get_module_info(!.CI, ModuleInfo),
	code_info__get_pred_id(!.CI, CallerPredId),
	code_info__get_proc_id(!.CI, CallerProcId),
	make_proc_label_hash_define(ModuleInfo, CallerPredId, CallerProcId,
		ProcLabelDefine, ProcLabelUndef),

	%
	% Generate a unique prefix for the C labels that we will define
	%
	ProcLabelString = make_proc_label_string(ModuleInfo,
		PredId, ProcId),

	%
	% Get a list of input and output arguments
	%
	ArgInfos = code_info__get_pred_proc_arginfo(!.CI, PredId, ProcId),
	make_c_arg_list(Args, ArgInfos, CArgs),
	pragma_select_in_args(CArgs, InCArgs),
	pragma_select_out_args(CArgs, OutCArgs),
	make_pragma_decls(CArgs, ModuleInfo, Decls),
	make_pragma_decls(OutCArgs, ModuleInfo, OutDecls),

	input_descs_from_arg_info(!.CI, InCArgs, InputDescs),
	output_descs_from_arg_info(!.CI, OutCArgs, OutputDescs),

	module_info_pred_info(ModuleInfo, PredId, PredInfo),
	ModuleName = pred_info_module(PredInfo),
	PredName = pred_info_name(PredInfo),
	Arity = pred_info_orig_arity(PredInfo),
	pragma_c_gen__struct_name(ModuleName, PredName, Arity, ProcId,
		StructName),
	SaveStructDecl = pragma_c_struct_ptr_decl(StructName, "LOCALS"),
	string__format("\tLOCALS = (struct %s *) ((char *)
		(MR_curfr + 1 - MR_ORDINARY_SLOTS - MR_NONDET_FIXED_SIZE)
		- sizeof(struct %s));\n",
		[s(StructName), s(StructName)],
		InitSaveStruct),

	code_info__get_next_label(RetryLabel, !CI),
	ModFrameCode = node([
		assign(redoip(lval(curfr)),
			const(code_addr_const(label(RetryLabel))))
			- "Set up backtracking to retry label"
	]),
	RetryLabelCode = node([
		label(RetryLabel) -
			"Start of the retry block"
	]),

	code_info__get_globals(!.CI, Globals),

	globals__lookup_bool_option(Globals, reclaim_heap_on_nondet_failure,
		ReclaimHeap),
	code_info__maybe_save_hp(ReclaimHeap, SaveHeapCode, MaybeHpSlot, !CI),
	code_info__maybe_restore_hp(MaybeHpSlot, RestoreHeapCode),

	globals__lookup_bool_option(Globals, use_trail, UseTrail),
	code_info__maybe_save_ticket(UseTrail, SaveTicketCode, MaybeTicketSlot,
		!CI),
	code_info__maybe_reset_ticket(MaybeTicketSlot, undo,
		RestoreTicketCode),

	(
		FirstContext = yes(ActualFirstContext)
	;
		FirstContext = no,
		term__context_init(ActualFirstContext)
	),
	trace__maybe_generate_pragma_event_code(nondet_pragma_first,
		ActualFirstContext, FirstTraceCode, !CI),
	(
		LaterContext = yes(ActualLaterContext)
	;
		LaterContext = no,
		term__context_init(ActualLaterContext)
	),
	trace__maybe_generate_pragma_event_code(nondet_pragma_later,
		ActualLaterContext, LaterTraceCode, !CI),

	FirstDisjunctCode =
		tree(SaveHeapCode,
		tree(SaveTicketCode,
		     FirstTraceCode)),
	LaterDisjunctCode =
		tree(RestoreHeapCode,
		tree(RestoreTicketCode,
		     LaterTraceCode)),

	%
	% MR_save_registers(); /* see notes (1) and (2) above */
	%
	(
		MayCallMercury = will_not_call_mercury,
		SaveRegs = ""
	;
		MayCallMercury = may_call_mercury,
		SaveRegs = "\tMR_save_registers();\n"
	),

	%
	% MR_restore_registers(); /* see notes (1) and (3) above */
	%
	( MayCallMercury = will_not_call_mercury ->
		RestoreRegs = ""
	;
		RestoreRegs = "\tMR_restore_registers();\n"
	),

	Succeed	 = "\tMR_succeed();\n",
	SucceedDiscard = "\tMR_succeed_discard();\n",

	CallDef1 = "#define\tSUCCEED     \tgoto MR_call_success_"
		++ ProcLabelString ++ "\n",
	CallDef2 = "#define\tSUCCEED_LAST\tgoto MR_call_success_last_"
		++ ProcLabelString ++ "\n",
	CallDef3 = "#define\tFAIL\tMR_fail()\n",

	CallSuccessLabel     = "MR_call_success_"
		++ ProcLabelString ++ ":\n",
	CallLastSuccessLabel = "MR_call_success_last_"
		++ ProcLabelString ++ ":\n",

	RetryDef1 = "#define\tSUCCEED     \tgoto MR_retry_success_"
		++ ProcLabelString ++ "\n",
	RetryDef2 = "#define\tSUCCEED_LAST\tgoto MR_retry_success_last_"
		++ ProcLabelString ++ "\n",
	RetryDef3 = "#define\tFAIL\tMR_fail()\n",

	RetrySuccessLabel     = "MR_retry_success_"
		++ ProcLabelString ++ ":\n",
	RetryLastSuccessLabel = "MR_retry_success_last_"
		++ ProcLabelString ++ ":\n",

	Undef1 = "#undef\tSUCCEED\n",
	Undef2 = "#undef\tSUCCEED_LAST\n",
	Undef3 = "#undef\tFAIL\n",

	(
			% Use the form that duplicates the common code
			% if the programmer asked for it, or if the code
			% is small enough for its duplication not to have
			% a significant effect on code size. (This form
			% generates slightly faster code.)
			% However, if `pragma no_inline' is specified,
			% then we don't duplicate the code unless the
			% programmer asked for it -- the code may contain
			% static variable declarations, so duplicating it
			% could change the semantics.

			% We use the number of semicolons in the code
			% as an indication how many C statements it has
			% and thus how big its object code is likely to be.
		(
			Treat = duplicate
		;
			Treat = automatic,
			\+ pred_info_requested_no_inlining(PredInfo),
			CountSemis = (pred(Char::in, Count0::in, Count::out)
					is det :-
				( Char = (;) ->
					Count = Count0 + 1
				;
					Count = Count0
				)
			),
			string__foldl(CountSemis, Shared, 0, Semis),
			Semis < 32
		)
	->
		CallDecls = [SaveStructDecl | Decls],
		CallComponents = [
			pragma_c_inputs(InputDescs),
			pragma_c_raw_code(InitSaveStruct, no_live_lvals_info),
			pragma_c_raw_code(SaveRegs, no_live_lvals_info),
			ProcLabelDefine,
			pragma_c_raw_code(CallDef1, no_live_lvals_info),
			pragma_c_raw_code(CallDef2, no_live_lvals_info),
			pragma_c_raw_code(CallDef3, no_live_lvals_info),
			pragma_c_user_code(FirstContext, First),
			pragma_c_user_code(SharedContext, Shared),
			pragma_c_raw_code(CallSuccessLabel, no_live_lvals_info),
			pragma_c_raw_code(RestoreRegs, no_live_lvals_info),
			pragma_c_outputs(OutputDescs),
			pragma_c_raw_code(Succeed, no_live_lvals_info),
			pragma_c_raw_code(CallLastSuccessLabel,
				no_live_lvals_info),
			pragma_c_raw_code(RestoreRegs, no_live_lvals_info),
			pragma_c_outputs(OutputDescs),
			pragma_c_raw_code(SucceedDiscard, no_live_lvals_info),
			pragma_c_raw_code(Undef1, no_live_lvals_info),
			pragma_c_raw_code(Undef2, no_live_lvals_info),
			pragma_c_raw_code(Undef3, no_live_lvals_info),
			ProcLabelUndef
		],
		CallBlockCode = node([
			pragma_c(CallDecls, CallComponents,
				MayCallMercury, no, no, no, no, yes, no)
				- "Call and shared pragma C inclusion"
		]),

		RetryDecls = [SaveStructDecl | OutDecls],
		RetryComponents = [
			pragma_c_raw_code(InitSaveStruct, no_live_lvals_info),
			pragma_c_raw_code(SaveRegs, no_live_lvals_info),
			ProcLabelDefine,
			pragma_c_raw_code(RetryDef1, no_live_lvals_info),
			pragma_c_raw_code(RetryDef2, no_live_lvals_info),
			pragma_c_raw_code(RetryDef3, no_live_lvals_info),
			pragma_c_user_code(LaterContext, Later),
			pragma_c_user_code(SharedContext, Shared),
			pragma_c_raw_code(RetrySuccessLabel,
				no_live_lvals_info),
			pragma_c_raw_code(RestoreRegs, no_live_lvals_info),
			pragma_c_outputs(OutputDescs),
			pragma_c_raw_code(Succeed, no_live_lvals_info),
			pragma_c_raw_code(RetryLastSuccessLabel,
				no_live_lvals_info),
			pragma_c_raw_code(RestoreRegs, no_live_lvals_info),
			pragma_c_outputs(OutputDescs),
			pragma_c_raw_code(SucceedDiscard, no_live_lvals_info),
			pragma_c_raw_code(Undef1, no_live_lvals_info),
			pragma_c_raw_code(Undef2, no_live_lvals_info),
			pragma_c_raw_code(Undef3, no_live_lvals_info),
			ProcLabelUndef
		],
		RetryBlockCode = node([
			pragma_c(RetryDecls, RetryComponents,
				MayCallMercury, no, no, no, no, yes, no)
				- "Retry and shared pragma C inclusion"
		]),

		Code =
			tree(ModFrameCode,
			tree(FirstDisjunctCode,
			tree(CallBlockCode,
			tree(RetryLabelCode,
			tree(LaterDisjunctCode,
			     RetryBlockCode)))))
	;
		code_info__get_next_label(SharedLabel, !CI),
		SharedLabelCode = node([
			label(SharedLabel) -
				"Start of the shared block"
		]),

		SharedDef1 =
			"#define\tSUCCEED     \tgoto MR_shared_success_"
			++ ProcLabelString ++ "\n",
		SharedDef2 =
			"#define\tSUCCEED_LAST\tgoto MR_shared_success_last_"
			++ ProcLabelString ++ "\n",
		SharedDef3 = "#define\tFAIL\tMR_fail()\n",

		SharedSuccessLabel     = "MR_shared_success_"
			++ ProcLabelString ++ ":\n",
		SharedLastSuccessLabel = "MR_shared_success_last_"
			++ ProcLabelString ++ ":\n",

		LabelStr = label_to_c_string(SharedLabel, yes),
		string__format("\tMR_GOTO_LABEL(%s);\n", [s(LabelStr)],
			GotoSharedLabel),

		CallDecls = [SaveStructDecl | Decls],
		CallComponents = [
			pragma_c_inputs(InputDescs),
			pragma_c_raw_code(InitSaveStruct, no_live_lvals_info),
			pragma_c_raw_code(SaveRegs, no_live_lvals_info),
			ProcLabelDefine,
			pragma_c_raw_code(CallDef1, no_live_lvals_info),
			pragma_c_raw_code(CallDef2, no_live_lvals_info),
			pragma_c_raw_code(CallDef3, no_live_lvals_info),
			pragma_c_user_code(FirstContext, First),
			pragma_c_raw_code(GotoSharedLabel, no_live_lvals_info),
			pragma_c_raw_code(CallSuccessLabel,
				no_live_lvals_info),
			pragma_c_raw_code(RestoreRegs, no_live_lvals_info),
			pragma_c_outputs(OutputDescs),
			pragma_c_raw_code(Succeed, no_live_lvals_info),
			pragma_c_raw_code(CallLastSuccessLabel,
				no_live_lvals_info),
			pragma_c_raw_code(RestoreRegs, no_live_lvals_info),
			pragma_c_outputs(OutputDescs),
			pragma_c_raw_code(SucceedDiscard, no_live_lvals_info),
			pragma_c_raw_code(Undef1, no_live_lvals_info),
			pragma_c_raw_code(Undef2, no_live_lvals_info),
			pragma_c_raw_code(Undef3, no_live_lvals_info),
			ProcLabelUndef
		],
		CallBlockCode = node([
			pragma_c(CallDecls, CallComponents, MayCallMercury,
				yes(SharedLabel), no, no, no, yes, no)
				- "Call pragma C inclusion"
		]),

		RetryDecls = [SaveStructDecl | OutDecls],
		RetryComponents = [
			pragma_c_raw_code(InitSaveStruct, no_live_lvals_info),
			pragma_c_raw_code(SaveRegs, no_live_lvals_info),
			ProcLabelDefine,
			pragma_c_raw_code(RetryDef1, no_live_lvals_info),
			pragma_c_raw_code(RetryDef2, no_live_lvals_info),
			pragma_c_raw_code(RetryDef3, no_live_lvals_info),
			pragma_c_user_code(LaterContext, Later),
			pragma_c_raw_code(GotoSharedLabel, no_live_lvals_info),
			pragma_c_raw_code(RetrySuccessLabel,
				no_live_lvals_info),
			pragma_c_raw_code(RestoreRegs, no_live_lvals_info),
			pragma_c_outputs(OutputDescs),
			pragma_c_raw_code(Succeed, no_live_lvals_info),
			pragma_c_raw_code(RetryLastSuccessLabel,
				no_live_lvals_info),
			pragma_c_raw_code(RestoreRegs, no_live_lvals_info),
			pragma_c_outputs(OutputDescs),
			pragma_c_raw_code(SucceedDiscard, no_live_lvals_info),
			pragma_c_raw_code(Undef1, no_live_lvals_info),
			pragma_c_raw_code(Undef2, no_live_lvals_info),
			pragma_c_raw_code(Undef3, no_live_lvals_info),
			ProcLabelUndef
		],
		RetryBlockCode = node([
			pragma_c(RetryDecls, RetryComponents, MayCallMercury,
				yes(SharedLabel), no, no, no, yes, no)
				- "Retry pragma C inclusion"
		]),

		SharedDecls = [SaveStructDecl | OutDecls],
		SharedComponents = [
			pragma_c_raw_code(InitSaveStruct, no_live_lvals_info),
			pragma_c_raw_code(SaveRegs, no_live_lvals_info),
			ProcLabelDefine,
			pragma_c_raw_code(SharedDef1, no_live_lvals_info),
			pragma_c_raw_code(SharedDef2, no_live_lvals_info),
			pragma_c_raw_code(SharedDef3, no_live_lvals_info),
			pragma_c_user_code(SharedContext, Shared),
			pragma_c_raw_code(SharedSuccessLabel,
				no_live_lvals_info),
			pragma_c_raw_code(RestoreRegs, no_live_lvals_info),
			pragma_c_outputs(OutputDescs),
			pragma_c_raw_code(Succeed, no_live_lvals_info),
			pragma_c_raw_code(SharedLastSuccessLabel,
				no_live_lvals_info),
			pragma_c_raw_code(RestoreRegs, no_live_lvals_info),
			pragma_c_outputs(OutputDescs),
			pragma_c_raw_code(SucceedDiscard, no_live_lvals_info),
			pragma_c_raw_code(Undef1, no_live_lvals_info),
			pragma_c_raw_code(Undef2, no_live_lvals_info),
			pragma_c_raw_code(Undef3, no_live_lvals_info),
			ProcLabelUndef
		],
		SharedBlockCode = node([
			pragma_c(SharedDecls, SharedComponents,
				MayCallMercury, no, no, no, no, yes, no)
				- "Shared pragma C inclusion"
		]),

		Code =
			tree(ModFrameCode,
			tree(FirstDisjunctCode,
			tree(CallBlockCode,
			tree(RetryLabelCode,
			tree(LaterDisjunctCode,
			tree(RetryBlockCode,
			tree(SharedLabelCode,
			     SharedBlockCode)))))))
	).

%---------------------------------------------------------------------------%

:- type c_arg
	--->	c_arg(
			prog_var,
			maybe(string),	% name
			type,		% original type before
					% inlining/specialization
					% (the actual type may be an instance
					% of this type, if this type is
					% polymorphic).
			arg_info
		).

:- pred make_c_arg_list(list(foreign_arg)::in, list(arg_info)::in,
	list(c_arg)::out) is det.

make_c_arg_list([], [], []).
make_c_arg_list([Arg | ArgTail], [ArgInfo | ArgInfoTail], [CArg | CArgTail]) :-
	Arg = foreign_arg(Var, MaybeNameMode, Type),
	(
		MaybeNameMode = yes(Name - _),
		MaybeName = yes(Name)
	;
		MaybeNameMode = no,
		MaybeName = no
	),
	CArg = c_arg(Var, MaybeName, Type, ArgInfo),
	make_c_arg_list(ArgTail, ArgInfoTail, CArgTail).
make_c_arg_list([], [_|_], _) :-
	error("pragma_c_gen__make_c_arg_list length mismatch").
make_c_arg_list([_|_], [], _) :-
	error("pragma_c_gen__make_c_arg_list length mismatch").

%---------------------------------------------------------------------------%

:- pred make_extra_c_arg_list(list(foreign_arg)::in, module_info::in,
	list(arg_info)::in, list(c_arg)::out) is det.

make_extra_c_arg_list(ExtraArgs, ModuleInfo, ArgInfos, ExtraCArgs) :-
	get_highest_arg_num(ArgInfos, 0, MaxArgNum),
	make_extra_c_arg_list_seq(ExtraArgs, ModuleInfo, MaxArgNum,
		ExtraCArgs).

:- pred get_highest_arg_num(list(arg_info)::in, int::in, int::out) is det.

get_highest_arg_num([], !Max).
get_highest_arg_num([arg_info(Loc, _) | ArgInfos], !Max) :-
	int__max(Loc, !Max),
	get_highest_arg_num(ArgInfos, !Max).

:- pred make_extra_c_arg_list_seq(list(foreign_arg)::in, module_info::in,
	int::in, list(c_arg)::out) is det.

make_extra_c_arg_list_seq([], _, _, []).
make_extra_c_arg_list_seq([ExtraArg | ExtraArgs], ModuleInfo, LastReg,
		[CArg | CArgs]) :-
	ExtraArg = foreign_arg(Var, MaybeNameMode, OrigType),
	(
		MaybeNameMode = yes(Name - Mode),
		mode_to_arg_mode(ModuleInfo, Mode, OrigType, ArgMode)
	;
		MaybeNameMode = no,
		error("make_extra_c_arg_list_seq: no name")
	),
	NextReg = LastReg + 1,
	% Extra args are always input.
	ArgInfo = arg_info(NextReg, ArgMode),
	CArg = c_arg(Var, yes(Name), OrigType, ArgInfo),
	make_extra_c_arg_list_seq(ExtraArgs, ModuleInfo, NextReg, CArgs).

%---------------------------------------------------------------------------%

:- pred get_c_arg_list_vars(list(c_arg)::in, list(prog_var)::out) is det.

get_c_arg_list_vars([], []).
get_c_arg_list_vars([Arg | Args], [Var | Vars]) :-
	Arg = c_arg(Var, _, _, _),
	get_c_arg_list_vars(Args, Vars).

%---------------------------------------------------------------------------%

	% pragma_select_out_args returns the list of variables
	% which are outputs for a procedure

:- pred pragma_select_out_args(list(c_arg)::in, list(c_arg)::out) is det.

pragma_select_out_args([], []).
pragma_select_out_args([Arg | Rest], Out) :-
	pragma_select_out_args(Rest, OutTail),
	Arg = c_arg(_, _, _, ArgInfo),
	ArgInfo = arg_info(_Loc, Mode),
	( Mode = top_out ->
		Out = [Arg | OutTail]
	;
		Out = OutTail
	).

	% pragma_select_in_args returns the list of variables
	% which are inputs for a procedure

:- pred pragma_select_in_args(list(c_arg)::in, list(c_arg)::out) is det.

pragma_select_in_args([], []).
pragma_select_in_args([Arg | Rest], In) :-
	pragma_select_in_args(Rest, InTail),
	Arg = c_arg(_, _, _, ArgInfo),
	ArgInfo = arg_info(_Loc, Mode),
	( Mode = top_in ->
		In = [Arg | InTail]
	;
		In = InTail
	).

%---------------------------------------------------------------------------%

% var_is_not_singleton determines whether or not a given pragma_c variable
% is singleton (i.e. starts with an underscore) or anonymous (in which case
% it's singleton anyway, it just doesn't necessarily have a singleton name).
%
% Singleton vars should be ignored when generating the declarations for
% pragma_c arguments because:
%
%	- they should not appear in the C code
% 	- they could clash with the system name space
%

:- pred var_is_not_singleton(maybe(string)::in, string::out) is semidet.

var_is_not_singleton(yes(Name), Name) :-
	\+ string__first_char(Name, '_', _).

%---------------------------------------------------------------------------%

% make_pragma_decls returns the list of pragma_decls for the pragma_c
% data structure in the LLDS. It is essentially a list of pairs of type and
% variable name, so that declarations of the form "Type Name;" can be made.

:- pred make_pragma_decls(list(c_arg)::in, module_info::in,
	list(pragma_c_decl)::out) is det.

make_pragma_decls([], _, []).
make_pragma_decls([Arg | Args], Module, Decls) :-
	make_pragma_decls(Args, Module, DeclsTail),
	Arg = c_arg(_Var, ArgName, OrigType, _ArgInfo),
	( var_is_not_singleton(ArgName, Name) ->
		OrigTypeString = foreign__to_type_string(c, Module, OrigType),
		Decl = pragma_c_arg_decl(OrigType, OrigTypeString, Name),
		Decls = [Decl | DeclsTail]
	;
		% if the variable doesn't occur in the ArgNames list,
		% it can't be used, so we just ignore it
		Decls = DeclsTail
	).

%---------------------------------------------------------------------------%

:- pred find_dead_input_vars(list(c_arg)::in, set(prog_var)::in,
	set(prog_var)::in, set(prog_var)::out) is det.

find_dead_input_vars([], _, !DeadVars).
find_dead_input_vars([Arg | Args], PostDeaths, !DeadVars) :-
	Arg = c_arg(Var, _MaybeName, _Type, _ArgInfo),
	( set__member(Var, PostDeaths) ->
		set__insert(!.DeadVars, Var, !:DeadVars)
	;
		true
	),
	find_dead_input_vars(Args, PostDeaths, !DeadVars).

%---------------------------------------------------------------------------%

% get_pragma_input_vars returns a list of pragma_c_inputs for the pragma_c
% data structure in the LLDS. It is essentially a list of the input variables,
% and the corresponding rvals assigned to those (C) variables.

:- pred get_pragma_input_vars(list(c_arg)::in, list(pragma_c_input)::out,
	code_tree::out, code_info::in, code_info::out) is det.

get_pragma_input_vars([], [], empty, !CI).
get_pragma_input_vars([Arg | Args], Inputs, Code, !CI) :-
	Arg = c_arg(Var, MaybeName, OrigType, _ArgInfo),
	( var_is_not_singleton(MaybeName, Name) ->
		VarType = variable_type(!.CI, Var),
		code_info__produce_variable(Var, FirstCode, Rval, !CI),
		MaybeForeign = get_maybe_foreign_type_info(!.CI, OrigType),
		Input = pragma_c_input(Name, VarType, OrigType, Rval,
			MaybeForeign),
		get_pragma_input_vars(Args, Inputs1, RestCode, !CI),
		Inputs = [Input | Inputs1],
		Code = tree(FirstCode, RestCode)
	;
		% if the variable doesn't occur in the ArgNames list,
		% it can't be used, so we just ignore it
		get_pragma_input_vars(Args, Inputs, Code, !CI)
	).

:- func get_maybe_foreign_type_info(code_info, (type)) =
	maybe(pragma_c_foreign_type).

get_maybe_foreign_type_info(CI, Type) = MaybeForeignTypeInfo :-
	code_info__get_module_info(CI, Module),
	module_info_types(Module, Types),

	(
		type_to_ctor_and_args(Type, TypeId, _SubTypes),
		map__search(Types, TypeId, Defn),
		hlds_data__get_type_defn_body(Defn, Body),
		Body = foreign_type(foreign_type_body(_MaybeIL, MaybeC,
			_MaybeJava))
	->
		(
			MaybeC = yes(Data),
			Data = foreign_type_lang_data(c(Name), _, Assertions),
			MaybeForeignTypeInfo = yes(
				pragma_c_foreign_type(Name, Assertions))
		;
			MaybeC = no,
			% This is ensured by check_foreign_type in
			% make_hlds.
			unexpected(this_file, "get_maybe_foreign_type_name: "
				++ "no c foreign type")
		)
	;
		MaybeForeignTypeInfo = no
	).

%---------------------------------------------------------------------------%

% pragma_acquire_regs acquires a list of registers in which to place each
% of the given arguments.

:- pred pragma_acquire_regs(list(c_arg)::in, list(lval)::out,
	code_info::in, code_info::out) is det.

pragma_acquire_regs([], [], !CI).
pragma_acquire_regs([Arg | Args], [Reg | Regs], !CI) :-
	Arg = c_arg(Var, _, _, _),
	code_info__acquire_reg_for_var(Var, Reg, !CI),
	pragma_acquire_regs(Args, Regs, !CI).

%---------------------------------------------------------------------------%

% place_pragma_output_args_in_regs returns a list of pragma_c_outputs, which
% are pairs of names of output registers and (C) variables which hold the
% output value.

:- pred place_pragma_output_args_in_regs(list(c_arg)::in, list(lval)::in,
	list(pragma_c_output)::out, code_info::in, code_info::out) is det.

place_pragma_output_args_in_regs([], [], [], !CI).
place_pragma_output_args_in_regs([Arg | Args], [Reg | Regs], Outputs, !CI) :-
	place_pragma_output_args_in_regs(Args, Regs, OutputsTail, !CI),
	Arg = c_arg(Var, MaybeName, OrigType, _ArgInfo),
	code_info__release_reg(Reg, !CI),
	( code_info__variable_is_forward_live(!.CI, Var) ->
		code_info__set_var_location(Var, Reg, !CI),
		MaybeForeign = get_maybe_foreign_type_info(!.CI, OrigType),
		( var_is_not_singleton(MaybeName, Name) ->
			VarType = variable_type(!.CI, Var),
			PragmaCOutput = pragma_c_output(Reg, VarType, OrigType,
				Name, MaybeForeign),
			Outputs = [PragmaCOutput | OutputsTail]
		;
			Outputs = OutputsTail
		)
	;
		Outputs = OutputsTail
	).
place_pragma_output_args_in_regs([_|_], [], _, !CI) :-
	error("place_pragma_output_args_in_regs: length mismatch").
place_pragma_output_args_in_regs([], [_|_], _, !CI) :-
	error("place_pragma_output_args_in_regs: length mismatch").

%---------------------------------------------------------------------------%

% input_descs_from_arg_info returns a list of pragma_c_inputs, which
% are pairs of rvals and (C) variables which receive the input value.

:- pred input_descs_from_arg_info(code_info::in, list(c_arg)::in,
	list(pragma_c_input)::out) is det.

input_descs_from_arg_info(_, [], []).
input_descs_from_arg_info(CI, [Arg | Args], Inputs) :-
	input_descs_from_arg_info(CI, Args, InputsTail),
	Arg = c_arg(Var, MaybeName, OrigType, ArgInfo),
	( var_is_not_singleton(MaybeName, Name) ->
		VarType = variable_type(CI, Var),
		ArgInfo = arg_info(N, _),
		Reg = reg(r, N),
		MaybeForeign = get_maybe_foreign_type_info(CI, OrigType),
		Input = pragma_c_input(Name, VarType, OrigType, lval(Reg),
			MaybeForeign),
		Inputs = [Input | InputsTail]
	;
		Inputs = InputsTail
	).

%---------------------------------------------------------------------------%

% output_descs_from_arg_info returns a list of pragma_c_outputs, which
% are pairs of names of output registers and (C) variables which hold the
% output value.

:- pred output_descs_from_arg_info(code_info::in, list(c_arg)::in,
	list(pragma_c_output)::out) is det.

output_descs_from_arg_info(_, [], []).
output_descs_from_arg_info(CI, [Arg | Args], Outputs) :-
	output_descs_from_arg_info(CI, Args, OutputsTail),
	Arg = c_arg(Var, MaybeName, OrigType, ArgInfo),
	( var_is_not_singleton(MaybeName, Name) ->
		VarType = variable_type(CI, Var),
		ArgInfo = arg_info(N, _),
		Reg = reg(r, N),
		MaybeForeign = get_maybe_foreign_type_info(CI, OrigType),
		Output = pragma_c_output(Reg, VarType, OrigType, Name,
			MaybeForeign),
		Outputs = [Output | OutputsTail]
	;
		Outputs = OutputsTail
	).

%---------------------------------------------------------------------------%

pragma_c_gen__struct_name(ModuleName, PredName, Arity, ProcId, StructName) :-
	MangledModuleName = sym_name_mangle(ModuleName),
	MangledPredName = name_mangle(PredName),
	proc_id_to_int(ProcId, ProcNum),
	string__int_to_string(Arity, ArityStr),
	string__int_to_string(ProcNum, ProcNumStr),
	string__append_list(["mercury_save__", MangledModuleName, "__",
		MangledPredName, "__", ArityStr, "_", ProcNumStr], StructName).

pragma_succ_ind_name = "MercurySuccessIndicator".

%---------------------------------------------------------------------------%

:- func this_file = string.
this_file = "pragma_c_gen.m".

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%
