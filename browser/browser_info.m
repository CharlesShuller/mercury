%---------------------------------------------------------------------------%
% Copyright (C) 2000-2003 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% File: browser_info.m
% Main author: Mark Brown
%
% Basic data structures used by the browser.
%

:- module mdb__browser_info.

:- interface.
:- import_module bool, list, std_util, io.

:- type browser_term
	--->	plain_term(
			univ		% We are browsing a plain term.
		)
	;	synthetic_term(
			string,		% We are browsing a synthetic term,
					% such as a predicate name applied to
					% a list of arguments. The string says
					% what we should print as the functor.
			list(univ),	% The arguments.
			maybe(univ)	% If yes, the synthetic term represents
					% a function call, and the argument
					% inside the yes() is the return value.
		).

	% The non-persistent browser information.  A new one of these is
	% created every time the browser is called, based on the contents
	% of the persistent state, and lasts for the duration of the call.
	%
:- type browser_info
	--->	browser_info(
			term		:: browser_term,
					% Term to browse.
			dirs		:: list(dir),
					% The list of directories to take,
					% starting from the root, to reach
					% the current subterm.
			caller_type	:: browse_caller_type,
					% What command called the browser?
			format		:: maybe(portray_format),
					% Format specified as an option to the
					% mdb command.
			state		:: browser_persistent_state,
					% Persistent settings.
			maybe_mark	:: maybe(list(dir))
					% Location of the marked term
					% relative to the root, or `no'
					% if there is no mark.
		).

:- type dir
	--->	parent
	;	child_num(int)
	;	child_name(string).

	% The browser is required to behave differently for different
	% caller circumstances.  The following type enumerates the
	% various possibilities.
	%
:- type browse_caller_type
	--->	print		% Non-interactively called via mdb's `print'
				% command, to print a single value.
	;	browse		% Interactively called via mdb's `browse'
				% command.
	;	print_all.	% Non-interactively called via mdb's `print *'
				% command, to print one of a sequence of
				% values.

	% The various ways of representing terms by the browser.
	%
:- type portray_format
	--->	flat
	;	raw_pretty	% calls pprint module directly, without first 
				% attempting to manipulate the term in any way.
	;	verbose
	;	pretty.		% It allows the user to specify the maximum 
				% number of lines which the term has to be 
				% printed within.

:- type format_params
	--->	format_params(
			depth	:: int,
			size	:: int,
			width	:: int,
			lines	:: int
		).

:- type setting
	--->	depth(int)
	;	size(int)
	;	format(portray_format)
	;	width(int)
	;	lines(int)
	;	num_io_actions(int).

	% Initialise a new browser_info.  The optional portray_format
	% overrides the default format.
	%
:- func browser_info__init(browser_term, browse_caller_type,
	maybe(portray_format), browser_persistent_state) = browser_info.

	% Get the format to use for the given caller type.  The optional
	% portray_format overrides the current default.
	%
:- pred browser_info__get_format(browser_info, browse_caller_type,
		maybe(portray_format), portray_format).
:- mode browser_info__get_format(in, in, in, out) is det.

	% Get the format parameters for the given caller type and format.
	%
:- pred browser_info__get_format_params(browser_info, browse_caller_type,
		portray_format, format_params).
:- mode browser_info__get_format_params(in, in, in, out) is det.

:- func browser_info__get_num_printed_io_actions(browser_persistent_state)
	= int.

%---------------------------------------------------------------------------%

	% An abstract data type that holds persistent browser settings.
	% This state must be saved by the caller of the browse module
	% between calls.
	%
:- type browser_persistent_state.

	% Initialize the persistent browser state with default values.
	%
:- pred browser_info__init_persistent_state(browser_persistent_state).
:- mode browser_info__init_persistent_state(out) is det.

	% Update a setting in the browser state.  The first seven arguments
	% indicate the presence of the `set' options -P, -B, -A, -f, -r, -v
	% and -p, in that order.
	%
:- pred browser_info__set_param(bool::in, bool::in, bool::in, bool::in,
	bool::in, bool::in, bool::in, setting::in, 
	browser_persistent_state::in, browser_persistent_state::out) is det.

	% Update a setting in the browser state.  The first argument
	% indicates the presence of at most one of the options -P, -B, -A,
	% while the next four indicate the presence of -f, -r, -v and -p,
	% in that order.
	%
:- pred browser_info__set_param(maybe(browse_caller_type)::in, bool::in,
	bool::in, bool::in, bool::in, setting::in, 
	browser_persistent_state::in, browser_persistent_state::out) is det.

%---------------------------------------------------------------------------%

% These three predicates are like the deconstruct, limited_deconstruct
% and functor procedures in deconstruct, except
%
% - they implicitly specify include_details_cc, and
% - they work on browser_terms instead of plain terms.
%
% The latter difference requires them to have an extra argument (the last).
% For deconstruct and limited_deconstruct, this returns the return value
% if the browser term represents a function call. For functor, it says
% whether the browser term represents a function call.

:- type browser_db
	--->	browser_db(
			browser_stream_db	:: io__stream_db
		).

:- pred deconstruct_browser_term_cc(browser_db::in, browser_term::in,
	string::out, int::out, list(univ)::out, maybe(univ)::out) is cc_multi.

:- pred limited_deconstruct_browser_term_cc(browser_db::in, browser_term::in,
	int::in, maybe({string, int, list(univ)})::out, maybe(univ)::out)
	is cc_multi.

:- pred functor_browser_term_cc(browser_db::in, browser_term::in, string::out,
	int::out, bool::out) is cc_multi.

%---------------------------------------------------------------------------%

:- implementation.
:- import_module deconstruct, require, io.

:- pragma export(browser_info__init_persistent_state(out),
		"ML_BROWSE_init_persistent_state").

	%
	% The following exported predicates are a convenient way to
	% call browser_info__set_param from C code.
	%

:- pred set_param_depth(bool::in, bool::in, bool::in, bool::in, bool::in,
		bool::in, bool::in, int::in, browser_persistent_state::in,
		browser_persistent_state::out) is det.
:- pragma export(set_param_depth(in, in, in, in, in, in, in, in, in, out),
		"ML_BROWSE_set_param_depth").

set_param_depth(P, B, A, F, Pr, V, NPr, Depth) -->
	browser_info__set_param(P, B, A, F, Pr, V, NPr,  depth(Depth)).

:- pred set_param_size(bool::in, bool::in, bool::in, bool::in, bool::in,
		bool::in, bool::in, int::in, browser_persistent_state::in,
		browser_persistent_state::out) is det.
:- pragma export(set_param_size(in, in, in, in, in, in, in, in, in, out),
		"ML_BROWSE_set_param_size").

set_param_size(P, B, A, F, Pr, NPr, V, Size) -->
	browser_info__set_param(P, B, A, F, Pr, V, NPr, size(Size)).

:- pred set_param_width(bool::in, bool::in, bool::in, bool::in, bool::in,
		bool::in, bool::in, int::in, browser_persistent_state::in,
		browser_persistent_state::out) is det.
:- pragma export(set_param_width(in, in, in, in, in, in, in, in, in, out),
		"ML_BROWSE_set_param_width").

set_param_width(P, B, A, F, Pr, V, NPr, Width) -->
	browser_info__set_param(P, B, A, F, Pr, V, NPr, width(Width)).

:- pred set_param_lines(bool::in, bool::in, bool::in, bool::in, bool::in,
		bool::in, bool::in, int::in, browser_persistent_state::in,
		browser_persistent_state::out) is det.
:- pragma export(set_param_lines(in, in, in, in, in, in, in, in, in, out),
		"ML_BROWSE_set_param_lines").

set_param_lines(P, B, A, F, Pr, V, NPr, Lines) -->
	browser_info__set_param(P, B, A, F, Pr, V, NPr, lines(Lines)).

:- pred set_param_format(bool::in, bool::in, bool::in, portray_format::in,
		browser_persistent_state::in, browser_persistent_state::out)
		is det.
:- pragma export(set_param_format(in, in, in, in, in, out),
		"ML_BROWSE_set_param_format").

set_param_format(P, B, A, Format) -->
	%
	% Any format flags are ignored for this parameter.
	%
	browser_info__set_param(P, B, A, no, no, no, no, format(Format)).

	%
	% The following exported functions allow C code to create
	% Mercury values of type bool.
	%

:- func mercury_bool_yes = bool.
:- pragma export(mercury_bool_yes = out, "ML_BROWSE_mercury_bool_yes").
mercury_bool_yes = yes.

:- func mercury_bool_no = bool.
:- pragma export(mercury_bool_no = out, "ML_BROWSE_mercury_bool_no").
mercury_bool_no = no.

%---------------------------------------------------------------------------%

browser_info__init(BrowserTerm, CallerType, MaybeFormat, State) =
	browser_info(BrowserTerm, [], CallerType, MaybeFormat, State, no).

browser_info__get_format(Info, Caller, MaybeFormat, Format) :-
	(
		MaybeFormat = yes(Format)
	;
		MaybeFormat = no,
		MdbFormatOption = Info ^ format,
		(
			MdbFormatOption = yes(Format)
		;
			MdbFormatOption = no,
			get_caller_params(Info ^ state, Caller, Params),
			Format = Params ^ default_format
		)
	).

browser_info__get_format_params(Info, Caller, Format, Params) :-
	get_caller_params(Info ^ state, Caller, CallerParams),
	get_caller_format_params(CallerParams, Format, Params).

%---------------------------------------------------------------------------%

:- type browser_persistent_state
	--->	browser_persistent_state(
			print_params		:: caller_params,
			browse_params		:: caller_params,
			print_all_params	:: caller_params,
			num_printed_io_actions	:: int
		).

:- type caller_params
	--->	caller_params(
			default_format		:: portray_format,
			flat_params		:: format_params,
			raw_pretty_params	:: format_params,
			verbose_params		:: format_params,
			pretty_params		:: format_params
		).

	% Initialise the persistent settings with default values.  The
	% rationale for the default values is:
	% 	Depth and Size:
	%		For non-interactive display, these are 3 and 10 resp.,
	%		so that terms will generally fit on one line.  For
	%		interactive browsing these values are increased.
	%
	%	Width:
	%		Defaults to 80 characters in any situation.
	%
	%	Lines:
	%		If one term is printed then it is limited to 25 lines.
	%		If there can be more than one term (i.e., with
	%		`print *') then a much lower limit is imposed.  For
	%		verbose format, there is not much point setting this to
	%		less than about 5 since otherwise very little of the
	%		term will be shown.
	%
browser_info__init_persistent_state(State) :-
	caller_type_print_defaults(Print),
	caller_type_browse_defaults(Browse),
	caller_type_print_all_defaults(PrintAll),
	State = browser_persistent_state(Print, Browse, PrintAll,
		num_printed_io_actions_default).

:- pred caller_type_print_defaults(caller_params).
:- mode caller_type_print_defaults(out) is det.

caller_type_print_defaults(Params) :-
	DefaultFormat = flat,
	Flat	  = format_params(3, 10, 80, 25),
	RawPretty = format_params(3, 10, 80, 25),
	Verbose	  = format_params(3, 10, 80, 25),
	Pretty    = format_params(3, 10, 80, 25),
	Params = caller_params(DefaultFormat, Flat, RawPretty, Verbose, Pretty).

:- pred caller_type_browse_defaults(caller_params).
:- mode caller_type_browse_defaults(out) is det.

caller_type_browse_defaults(Params) :-
	DefaultFormat = verbose,
	Flat	  = format_params(10, 30, 80, 25),
	RawPretty = format_params(10, 30, 80, 25),
	Verbose	  = format_params(10, 30, 80, 25),
	Pretty    = format_params(10, 30, 80, 25),
	Params = caller_params(DefaultFormat, Flat, RawPretty, Verbose, Pretty).

:- pred caller_type_print_all_defaults(caller_params).
:- mode caller_type_print_all_defaults(out) is det.

caller_type_print_all_defaults(Params) :-
	DefaultFormat = flat,
	Flat	  = format_params(3, 10, 80, 2),
	RawPretty = format_params(3, 10, 80, 2),
	Verbose   = format_params(3, 10, 80, 5),
	Pretty    = format_params(3, 10, 80, 2),
	Params = caller_params(DefaultFormat, Flat, RawPretty, Verbose, Pretty).

:- func num_printed_io_actions_default = int.

% Since each I/O action typically takes one line, this usually leaves room
% on the typical 24-line screen for the atom, the query, and some previous
% context.
num_printed_io_actions_default = 20.

browser_info__set_param(MaybeCallerType, F0, Pr0, V0, NPr0, Setting, State0,
		State) :-
	affected_caller_types(MaybeCallerType, P, B, A),
	browser_info__set_param(P, B, A, F0, Pr0, V0, NPr0, Setting, State0,
		State).

browser_info__set_param(P0, B0, A0, F0, Pr0, V0, NPr0, Setting, State0,
		State) :-
	( Setting = num_io_actions(NumIoActions) ->
		State = State0 ^ num_printed_io_actions := NumIoActions
	;
		default_all_yes(P0, B0, A0, P, B, A),
		default_all_yes(F0, Pr0, V0, NPr0, F, Pr, V, NPr),
		PParams0 = State0 ^ print_params,
		BParams0 = State0 ^ browse_params,
		AParams0 = State0 ^ print_all_params,
		maybe_set_param(P, F, Pr, V, NPr, Setting, PParams0, PParams),
		maybe_set_param(B, F, Pr, V, NPr, Setting, BParams0, BParams),
		maybe_set_param(A, F, Pr, V, NPr, Setting, AParams0, AParams),
		State = browser_persistent_state(PParams, BParams, AParams,
			State0 ^ num_printed_io_actions)
	).

:- pred affected_caller_types(maybe(browse_caller_type)::in,
	bool::out, bool::out, bool::out) is det.

	%
	% If no caller type is specified, the command by default
	% applies to _all_ caller types.
	%
affected_caller_types(no,             yes, yes, yes).
affected_caller_types(yes(print),     yes, no, no).
affected_caller_types(yes(browse),    no, yes, no).
affected_caller_types(yes(print_all), no, no, yes).

:- pred default_all_yes(bool, bool, bool, bool, bool, bool).
:- mode default_all_yes(in, in, in, out, out, out) is det.

default_all_yes(A0, B0, C0, A, B, C) :-
	%
	% If none of the flags are set, the command by default
	% applies to _all_ caller types/formats.
	%
	(
		A0 = no,
		B0 = no,
		C0 = no
	->
		A = yes,
		B = yes,
		C = yes
	;
		A = A0,
		B = B0,
		C = C0
	).

:- pred default_all_yes(bool, bool, bool, bool, bool, bool, bool, bool).
:- mode default_all_yes(in, in, in, in, out, out, out, out) is det.

default_all_yes(A0, B0, C0, D0, A, B, C, D) :-
	%
	% If none of the format flags are set, the command by default
	% applies to _all_ formats.
	%
	(
		A0 = no,
		B0 = no,
		C0 = no,
		D0 = no
	->
		A = yes,
		B = yes,
		C = yes,
		D = yes
	;
		A = A0,
		B = B0,
		C = C0,
		D = D0
	).

:- pred maybe_set_param(bool, bool, bool, bool, bool, setting, caller_params,
		caller_params).
:- mode maybe_set_param(in, in, in, in, in, in, in, out) is det.

maybe_set_param(no, _, _, _, _, _, Params, Params).
maybe_set_param(yes, F, Pr, V, NPr, Setting, Params0, Params) :-
	( Setting = format(NewFormat) ->
		Params = Params0 ^ default_format := NewFormat
	;
		Format0 = Params0 ^ default_format,
		FParams0 = Params0 ^ flat_params,
		PrParams0 = Params0 ^ raw_pretty_params,
		VParams0 = Params0 ^ verbose_params,
		NPrParams0 = Params0 ^ pretty_params,
		maybe_set_param_2(F, Setting, FParams0, FParams),
		maybe_set_param_2(Pr, Setting, PrParams0, PrParams),
		maybe_set_param_2(V, Setting, VParams0, VParams),
		maybe_set_param_2(NPr, Setting, NPrParams0, NPrParams),
		Params = caller_params(Format0,
			FParams, PrParams, VParams, NPrParams)
	).

:- pred maybe_set_param_2(bool, setting, format_params, format_params).
:- mode maybe_set_param_2(in, in, in, out) is det.

maybe_set_param_2(no, _, Params, Params).
maybe_set_param_2(yes, depth(D), Params, Params ^ depth := D).
maybe_set_param_2(yes, size(S), Params, Params ^ size := S).
maybe_set_param_2(yes, format(_), _, _) :-
	error("maybe_set_param_2: cannot set format here").
maybe_set_param_2(yes, width(W), Params, Params ^ width := W).
maybe_set_param_2(yes, lines(L), Params, Params ^ lines := L).
maybe_set_param_2(yes, num_io_actions(_), _, _) :-
	error("maybe_set_param_2: num_io_actions").

:- pred get_caller_params(browser_persistent_state, browse_caller_type,
		caller_params).
:- mode get_caller_params(in, in, out) is det.

get_caller_params(State, print, State ^ print_params).
get_caller_params(State, browse, State ^ browse_params).
get_caller_params(State, print_all, State ^ print_all_params).

:- pred get_caller_format_params(caller_params, portray_format, format_params).
:- mode get_caller_format_params(in, in, out) is det.

get_caller_format_params(Params, flat, Params ^ flat_params).
get_caller_format_params(Params, raw_pretty, Params ^ raw_pretty_params).
get_caller_format_params(Params, verbose, Params ^ verbose_params).
get_caller_format_params(Params, pretty, Params ^ pretty_params).

browser_info__get_num_printed_io_actions(State) =
	State ^ num_printed_io_actions.

%---------------------------------------------------------------------------%

:- pred browser_persistent_state_type(type_info).
:- mode browser_persistent_state_type(out) is det.
:- pragma export(browser_persistent_state_type(out),
		"ML_BROWSE_browser_persistent_state_type").

browser_persistent_state_type(type_of(State)) :-
	browser_info__init_persistent_state(State).

%---------------------------------------------------------------------------%

deconstruct_browser_term_cc(BrowserDb, BrowserTerm, Functor, Arity,
		Args, MaybeReturn) :-
	(
		BrowserTerm = plain_term(Univ),
		deconstruct__deconstruct(pretty_value(BrowserDb, Univ),
			include_details_cc, Functor, Arity, Args),
		MaybeReturn = no
	;
		BrowserTerm = synthetic_term(Functor, Args, MaybeReturn),
		list__length(Args, Arity)
	).

limited_deconstruct_browser_term_cc(BrowserDb, BrowserTerm, Limit,
		MaybeFunctorArityArgs, MaybeReturn) :-
	(
		BrowserTerm = plain_term(Univ),
		deconstruct__limited_deconstruct_cc(
			pretty_value(BrowserDb, Univ), Limit,
			MaybeFunctorArityArgs),
		MaybeReturn = no
	;
		BrowserTerm = synthetic_term(Functor, Args, MaybeReturn),
		list__length(Args, Arity),
		MaybeFunctorArityArgs = yes({Functor, Arity, Args})
	).

functor_browser_term_cc(BrowserDb, BrowserTerm, Functor, Arity, IsFunc) :-
	(
		BrowserTerm = plain_term(Univ),
		deconstruct__functor(pretty_value(BrowserDb, Univ),
			include_details_cc, Functor, Arity),
		IsFunc = no
	;
		BrowserTerm = synthetic_term(Functor, Args, MaybeReturn),
		list__length(Args, Arity),
		(
			MaybeReturn = yes(_),
			IsFunc = yes
		;
			MaybeReturn = no,
			IsFunc = no
		)
	).

:- some [T] func pretty_value(browser_db, univ) = T.

pretty_value(BrowserDb, Univ0) = Value :-
	( univ_to_type(Univ0, InputStream) ->
		io__input_stream_info(BrowserDb ^ browser_stream_db,
			InputStream) = InputStreamInfo,
		type_to_univ(InputStreamInfo, Univ)
	; univ_to_type(Univ0, OutputStream) ->
		io__output_stream_info(BrowserDb ^ browser_stream_db,
			OutputStream) = OutputStreamInfo,
		type_to_univ(OutputStreamInfo, Univ)
	; univ_to_type(Univ0, BinaryInputStream) ->
		io__binary_input_stream_info(BrowserDb ^ browser_stream_db,
			BinaryInputStream) = BinaryInputStreamInfo,
		type_to_univ(BinaryInputStreamInfo, Univ)
	; univ_to_type(Univ0, BinaryOutputStream) ->
		io__binary_output_stream_info(BrowserDb ^ browser_stream_db,
			BinaryOutputStream) = BinaryOutputStreamInfo,
		type_to_univ(BinaryOutputStreamInfo, Univ)
	;
		Univ = Univ0
	),
	Value = univ_value(Univ).

%---------------------------------------------------------------------------%
