%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 1999-2000, 2003, 2005-2006 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%-----------------------------------------------------------------------------%
% File: declarative_test.m
% Author: Mark Brown
%
% This module is a stand-alone version of the front end, suitable for
% testing.

:- module declarative_test.

:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module mdb.
:- import_module mdb.declarative_debugger.
:- import_module mdb.declarative_execution.

:- import_module list.
:- import_module map.
:- import_module require.

main(!IO) :-
    process_arguments(MaybeFile, !IO),
    (
        MaybeFile = yes(File),
        load_trace_node_map(File, Map, Key, !IO),
        io.stdin_stream(StdIn, !IO),
        io.stdout_stream(StdOut, !IO),
        diagnoser_state_init(StdIn, StdOut, State),
        diagnosis(Map, Key, Response, State, _, !IO),
        io.write_string("Diagnoser response:\n", !IO),
        io.write(Response, !IO),
        io.nl(!IO)
    ;
        MaybeFile = no,
        usage(!IO)
    ).

:- pred process_arguments(maybe(io.input_stream)::out, io::di, io::uo) is det.

process_arguments(MaybeFile, !IO) :-
    io.command_line_arguments(Args, !IO),
    ( Args = [FileName] ->
        io.open_input(FileName, Res, !IO),
        ( Res = ok(File) ->
            MaybeFile = yes(File)
        ;
            MaybeFile = no
        )
    ;
        MaybeFile = no
    ).

:- pred usage(io::di, io::uo) is det.

usage(!IO) :-
    io.progname_base("declarative_test", Name, !IO),
    io.write_strings(["Usage: ", Name, " <filename>\n"], !IO).
