%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 2012 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% This module contains utility predicates that may be useful in several
% directories of the Mercury system.

:- module mdbcomp.shared_utilities.
:- interface.

:- import_module io.

    % When the deep profiler is compiled in hlc grades, on many systems
    % large profiling data files cannot be processed using only the default
    % size of the C stack. Similarly, when the compiler is compiled in hlc
    % grades, it often runs out of stack when compiling large input files.
    %
    % This predicate tells the OS to allow the system stack to grow
    % as large as it needs to, subject only to the hard limits enforced
    % by the system.
    %
    % In llc grades, this predicate has no useful effect. The stack size
    % limit can be lifted in such grades by using their .stseg versions.
    %
:- pred unlimit_stack(io::di, io::uo) is det.

:- implementation.

:- pragma foreign_proc("C",
    unlimit_stack(S0::di, S::uo),
    [will_not_call_mercury, promise_pure],
"{
    struct rlimit   limit_struct;
    rlim_t          max_value;

    if (getrlimit(RLIMIT_STACK, &limit_struct) != 0) {
        MR_fatal_error(""could not get current stack limit"");
    }

    max_value = limit_struct.rlim_max;
    limit_struct.rlim_cur = limit_struct.rlim_max;
    /* If this fails, we have no recourse, so ignore any failure. */
    (void) setrlimit(RLIMIT_STACK, &limit_struct);

    S = S0;
}").

%---------------------------------------------------------------------------%
