%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2002, 2005-2006 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
% 
% File: term_constr_data.m.
% Main author: juliensf.
% 
% This module defines data structures that are common to all modules in the
% termination analyser.
%
% The main data structure defined here is the abstract representation (AR),
% which is an abstraction of a Mercury program in terms of linear arithmetic
% constraints on term sizes.
% 
%------------------------------------------------------------------------------%
%
% AR Goals. 
%
% The AR has four kinds of goal:
%
% * primitives      - a set of primitive constraints representing the 
%                     abstraction variable size relationships in some
%                     HLDS goal. 
%                     
% * conjunction     - a conjunction of AR goals.
% 
% * disjunction     - a disjunction of AR goals.
%
% * calls           - an abstraction of intra-SCC calls.  Calls to
%                     procedures lower down the call-graph are abstracted
%                     as primitive AR goals.
% 
% XXX In order to handle higher-order we need to either modify the
% exiting AR call goal or add a new AR goal type.
% 
%------------------------------------------------------------------------------%
%
% Mapping the HLDS to the AR
%
% 
% 1. unification
%
% A HLDS unification of the form: 
%   
%       X = f(A, B, C) 
%   
% is converted to a AR primitive goal of the form:
%
%       { |X| = |A| + |B| + |C| + |f| }
%
% where |X| represents the size of the variable X (according to whatever
% measure we are using).  There will also additional non-negativity
% constraints on any variables that have non-zero size type.  Variables
% of that have zero size type are not included at all.  Variables that
% represent polymorphic types are included.  The code in
% term_constr_fixpoint.m and term_constr_pass2.m that processes calls is
% responsible for dealing with the situation where a polymorphic
% procedure is called with zero sized arguments.   
%
% 2. conjunction and parallel conjunction
%
% A HLDS conjunction (A, B) is converted to an AR conjunction.  Parallel
% conjunction is treated the same way.
%
% 3. disjunction and switches.
%
% A HLDS disjunction (A ; B) is converted to an AR disjunction.  Switches
% are similar although we also have to add any constraints on the variable
% being switched on.
%
% 4. calls
%
% A HLDS call to a procedure lower down the call graph is abstracted as
% an AR primitive.  A call to something in the same SCC becomes an AR call.
%
% 5. negation.
%
% A HLDS negation is abstracted as an AR primitive. 
% The analyser tries to infer bounds upon the sizes of any input variables
% of the negated goal when if fails.
%
% 6. scopes 
%
% Scope goals, such as existential quantifications, that do not
% affect term size are ignored.
% 
% 8. if-then-else.
% 
% ( Cond -> Then ; Else ) is abstracted as
%  
%  disj(conj(|Cond|, |Then|), conj(neg(|Cond|), |Else|))
% 
% (using |Goal| to represent the abstraction of Goal).
% 
% 9. foreign_procs
%
% Currently these map onto a primitive whose variables are unconstrained.
% XXX Could do better with user supplied information.
% 
% 10. generic call.
% 
% XXX As above, need HO analysis to make these work.
%
%-----------------------------------------------------------------------------%

:- module transform_hlds.term_constr_data.

:- interface.

:- import_module hlds.hlds_module.
:- import_module hlds.hlds_pred. 
:- import_module libs.lp_rational.
:- import_module libs.polyhedron.
:- import_module parse_tree.prog_data.
:- import_module transform_hlds.term_constr_errors.

:- import_module bool.
:- import_module io.
:- import_module list.
:- import_module map.
:- import_module set.   % XXX We should experiment with different set
                        % implementations.

%-----------------------------------------------------------------------------%
%
% Types that are common to all parts of the termination analyser.
%

    % A size_var is a variable that represents the size (according
    % to some measure) of a program variable.
    % 
:- type size_var    == lp_var.
:- type size_vars   == list(size_var).
:- type size_varset == lp_varset.

:- type size_term  == lp_term.
:- type size_terms == lp_terms.

    % A map between prog_vars and their corresponding size_vars.
    %
:- type size_var_map == map(prog_var, size_var).

    % The widening strategy used in the fixpoint calculation.
    % (At present there is only one but we may add others in the future).
    %
:- type widening ---> after_fixed_cutoff(int).

    % The result of the argument size analysis.
    %
    % NOTE: this is just an indication that everything worked, any
    % argument size constraint derived will be stored in the
    % termination2_info structure.
    %
:- type arg_size_result 
    --->    ok      
    ;       error(term2_errors).

%-----------------------------------------------------------------------------%
%
% The abstract representation.
%

% XXX There should really be a representation for abstract SCCs as
% some of the data in the abstract_proc structure is actually information
% about the SCC; currently the relevant information is just duplicated
% amongst the abstract procs.

:- type abstract_scc == list(abstract_proc).

    % XXX This will need to be extended in order to handle HO calls and
    % intermodule mutual recursion.
    %
    % The idea here is that information about procedures from other
    % modules/HO information will be turned into `fake' abstract procs.
    % Using these fake procs we will then fill in the missing bits of
    % the SCCs that involve intermodule mutual recursion/HO calls, and
    % then run the analysis on them.
    %
    % This is the main reason that we try a eliminate, as much as
    % possible, dependencies between the AR and the HLDS.
    %
:- type abstract_ppid ---> real(pred_proc_id).

:- type abstract_proc  
    ---> abstract_proc(
        ppid :: abstract_ppid,
            % The procedure that this is an abstraction of.     

        context :: prog_context,
            % The context of the procedure.
    
        recursion :: recursion_type,
            % The type of recursion present in the procedure.

        size_var_map :: size_var_map,
            % Map from prog_vars to size_vars for the procedure.
        
        head_vars :: head_vars,
            % The procedure's arguments (as size_vars).     

        inputs :: list(bool),
            % `yes' if the corresponding argument can be used
            % as part of a termination proof, `no' otherwise.
    
        zeros :: zero_vars,
            % The size_vars that have zero size.

        body :: abstract_goal,
            % An abstraction of the body of the procedure. 
        
        calls :: int,
            % The number of calls made in the body of the
            % procedure.  This is useful for short-circuiting
            % pass 2.
         
        varset :: size_varset,
            % The varset from which the size_vars were
            % allocated.  The linear solver needs this.

        ho :: list(abstract_ho_call),
            % A list of higher-order calls made by the 
            % procedure.  XXX Currently not used.
            
        is_entry :: bool
            % Is this procedure called from outside the SCC?
    ).

    % This is like an error message (and is treated as such
    % at the moment).  It's here because we want to treat information
    % regarding higher-order constructs differently from other errors.
    % In particular higher-order constructs will not always be errors
    % (ie. when we can analyse them properly).  
    %
:- type abstract_ho_call ---> ho_call(prog_context).

    % NOTE: the AR's notion of local/non-local variables may not
    % correspond directly to that in the HLDS because of various
    % transformations performed on the the AR.
    %
:- type local_vars == size_vars. 
:- type nonlocal_vars == size_vars.

:- type call_vars == size_vars.
:- type head_vars == size_vars.

    % `zero_vars' are those variables in a procedure that have
    % zero size type (as defined in term_norm.m).
    %
:- type zero_vars == set(size_var).  

    % This is the representation of goals that the termination analyser
    % works with.
    %
:- type abstract_goal
    --->    term_disj(
                disj_goals     :: abstract_goals,
                disj_size      :: int,
                        % We keep track of the number of disjuncts for use
                        % in heuristics that may speed up the convex hull
                        % calculation.
                        
                disj_locals    :: local_vars,
                disj_nonlocals :: nonlocal_vars
            )
        
    ;       term_conj(
                conj_goals     :: abstract_goals, 
                conj_locals    :: local_vars, 
                conj_nonlocals :: nonlocal_vars
            )
        
    ;       term_call(
                call_ppid      :: abstract_ppid, 
                call_context   :: prog_context, 
                call_vars      :: call_vars, 
                call_zeros     :: zero_vars, 
                call_locals    :: local_vars, 
                call_nonlocals :: nonlocal_vars,
                call_constrs   :: polyhedron
            )
        
    ;       term_primitive(
                prim_constrs   :: polyhedron,
                prim_locals    :: local_vars,
                prim_nonlocals :: nonlocal_vars
            ). 

:- type abstract_goals == list(abstract_goal). 

    % This type is used to keep track of intramodule recursion during
    % the build pass.
    %
    % NOTE: if a procedure is (possibly) involved in intermodule recursion
    % we handle things differently.
    %
:- type recursion_type
    --->    none        % Procedure is not recursive.
    
    ;       direct_only % Only recursion is self-calls.
    
    ;       mutual_only % Only recursion is calls to other procs
                        % in the same SCC.

    ;       both.       % Both types of recursion.

%-----------------------------------------------------------------------------%
%
% Functions that operate on the AR.
%

    % Update the local and nonlocal variable sets associated with an
    % abstract goal.
    %
:- func update_local_and_nonlocal_vars(abstract_goal, local_vars, 
    nonlocal_vars) = abstract_goal.

    % For any two goals whose recursion types are known return the
    % recursion type of the conjunction of the two goals.
    %
:- func combine_recursion_types(recursion_type, recursion_type) 
    = recursion_type.

    % Combines the constraints contained in two primitive goals
    % into a single primitive goal.  It is an error to pass
    % any other kind of abstract goal as an argument to this 
    % function.
    %
:- func combine_primitive_goals(abstract_goal, abstract_goal) = abstract_goal.

    % Take a list of conjoined primitive goals and simplify them
    % so there is one large block of constraints.
    %
:- func simplify_abstract_rep(abstract_goal) = abstract_goal.
:- func simplify_conjuncts(abstract_goals) = abstract_goals.

    % Succeeds iff the given SCC contains recursion.
    % 
:- pred scc_contains_recursion(abstract_scc::in) is semidet.

    % Succeeds iff the given procedure is recursive (either directly
    % or otherwise).
    % 
:- pred proc_is_recursive(abstract_proc::in) is semidet.

    % Returns the size_varset for this given SCC. 
    %
:- func varset_from_abstract_scc(abstract_scc) = size_varset.

    % Succeeds iff the results of the analysis depend upon the 
    % values of some higher-order variables.
    %
:- pred analysis_depends_on_ho(abstract_proc::in) is semidet.

%-----------------------------------------------------------------------------%
% 
% Predicates for printing out debugging traces, etc.
%

    % Dump a representation of the AR to stdout.
    %
:- pred dump_abstract_scc(abstract_scc::in, module_info::in, io::di,
    io::uo) is det.
    
    % As above.  The extra argument specifies the indentation level.    
    %
:- pred dump_abstract_scc(abstract_scc::in, int::in, module_info::in, io::di,
    io::uo) is det.

    % Write an abstract_proc to stdout.
    %
:- pred dump_abstract_proc(abstract_proc::in, int::in, module_info::in,
    io::di, io::uo) is det.

    % Write an abstract_goal to stdout.
    %
:- pred dump_abstract_goal(module_info::in, size_varset::in, int::in, 
    abstract_goal::in, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module hlds.hlds_pred. 
:- import_module hlds.hlds_out.
:- import_module libs.compiler_util.
:- import_module parse_tree.prog_data.

:- import_module int.
:- import_module std_util.
:- import_module string.
:- import_module varset.
:- import_module term.

%-----------------------------------------------------------------------------%
%
% Functions that operate on the AR.
%

update_local_and_nonlocal_vars(Goal0, Locals0, NonLocals0) = Goal :-
    (
        Goal0     = term_disj(Goals, Size, Locals1, NonLocals1),
        Locals    = Locals0 ++ Locals1,
        NonLocals = NonLocals0 ++ NonLocals1,
        Goal      = term_disj(Goals, Size, Locals,  NonLocals)
    ;
        Goal0     = term_conj(Goals, Locals1, NonLocals1),
        Locals    = Locals0 ++ Locals1,
        NonLocals = NonLocals0 ++ NonLocals1,
        Goal      = term_conj(Goals, Locals, NonLocals)
    ;
        Goal0     = term_call(PPId, Context, CallVars, Zeros, Locals1,
                        NonLocals1, Polyhedron),
        Locals    = Locals0 ++ Locals1,
        NonLocals = NonLocals0 ++ NonLocals1,
        Goal      = term_call(PPId, Context, CallVars, Zeros, Locals,
                        NonLocals, Polyhedron)
    ;
        Goal0     = term_primitive(Polyhedron, Locals1, NonLocals1),
        Locals    = Locals0 ++ Locals1,
        NonLocals = NonLocals0 ++ NonLocals1,
        Goal      = term_primitive(Polyhedron, Locals, NonLocals)
    ).  

scc_contains_recursion([]) :-
    unexpected(this_file, "empty SCC.").
scc_contains_recursion([Proc | _]) :-
    Proc ^ recursion \= none. 

proc_is_recursive(Proc) :-
    not Proc ^ recursion = none.

varset_from_abstract_scc([]) = _ :-
    unexpected(this_file, "empty SCC.").
varset_from_abstract_scc([Proc | _]) = Proc ^ varset.

analysis_depends_on_ho(Proc) :-
    list.is_not_empty(Proc ^ ho).

%-----------------------------------------------------------------------------%
%
% Code for simplifying the abstract representation.
%

% XXX We should keep running the simplifications until we arrive at a
% fixpoint.

simplify_abstract_rep(Goal0) = Goal :- simplify_abstract_rep(Goal0, Goal).

:- pred simplify_abstract_rep(abstract_goal::in, abstract_goal::out) is det.

simplify_abstract_rep(term_disj(!.Disjuncts, _Size0, Locals, NonLocals),
        Goal) :-
    %
    % Begin by simplifying each disjunct.
    %
    list.map(simplify_abstract_rep, !Disjuncts),
    ( 
        !.Disjuncts = [Disjunct] 
    ->
        % We need to merge the set of locals with the locals from the 
        % disjunct otherwise we will end up throwing away the locals
        % from the enclosing goal.
        %
        Goal = update_local_and_nonlocal_vars(Disjunct, Locals, NonLocals)
    ;   
        !.Disjuncts = [] 
    ->
        Goal = term_primitive(polyhedron.universe, [], [])
    ;
        Size = list.length(!.Disjuncts),
        Goal = term_disj(!.Disjuncts, Size, Locals, NonLocals) 
    ).

simplify_abstract_rep(term_conj(!.Conjuncts, Locals, NonLocals), Goal) :-
    list.map(simplify_abstract_rep, !Conjuncts),
    list.filter(isnt(is_empty_primitive), !Conjuncts),
    flatten_conjuncts(!Conjuncts),
    list.filter(isnt(is_empty_conj), !Conjuncts),
    ( !.Conjuncts = [Conjunct] ->
        %
        % The local/non-local var sets need to be updated for similar
        % reasons as we do with disjunctions.
        %
        Goal = update_local_and_nonlocal_vars(Conjunct, Locals,
            NonLocals) 
    ; 
        Goal = term_conj(!.Conjuncts, Locals, NonLocals)
    ).

simplify_abstract_rep(Goal @ term_primitive(_,_,_),      Goal).
simplify_abstract_rep(Goal @ term_call(_,_,_,_,_,_,_), Goal).

    % Given a conjuntion of abstract goals take the intersection
    % of all consecutive primitive goals in the list of abstract goals.
    % 
    % e.g if we have
    %
    %   [ P1, P2, P3, NP1, NP2, P4, P5, NP3, P6, P7 ]
    %
    %   where Px is a primitive goal and NPx is a non-primitive
    %
    %   then simplify this to:
    %
    %   [ ( P1 /\ P2 /\ P3), NP1, NP2, ( P4 /\ P5), NP3, (P6 /\ P7) ] 
    %
    %   where `/\' is the intersection of the primitive goals. 
    %
    % Note: because intersection is commutative we could go further
    % and take the intersection of all the primitive goals in a
    % conjunction but that unnecessarily increases the size of the edge
    % labels in pass 2.
    %
:- pred flatten_conjuncts(abstract_goals::in, abstract_goals::out) is det.

flatten_conjuncts([], []).
flatten_conjuncts([Goal], [Goal]).
flatten_conjuncts(Goals0 @ [_, _ | _], Goals) :-
    flatten_conjuncts_2(Goals0, [], Goals1),
    Goals = list.reverse(Goals1).

:- pred flatten_conjuncts_2(abstract_goals::in, abstract_goals::in,
    abstract_goals::out) is det.

flatten_conjuncts_2([], !Goals).
flatten_conjuncts_2([Goal0 | Goals0], !Goals) :-
    ( Goal0 = term_primitive(_, _, _) ->
        list.takewhile(is_primitive, Goals0, Primitives, NextNonPrimitive),
        ( Primitives = [_|_] ->
            NewPrimitive = list.foldl(combine_primitives, Primitives, Goal0)
        ;
            NewPrimitive = Goal0
        ),
        list.cons(NewPrimitive, !Goals)
    ;
        list.cons(Goal0, !Goals),
        NextNonPrimitive = Goals0
    ),
    flatten_conjuncts_2(NextNonPrimitive, !Goals).

    % Test whether an abstract goal is a primtive.
    %
:- pred is_primitive(abstract_goal::in) is semidet.

is_primitive(term_primitive(_, _, _)).

:- func combine_primitives(abstract_goal, abstract_goal) = abstract_goal.

combine_primitives(GoalA, GoalB) = Goal :-
    (
        GoalA = term_primitive(PolyA, LocalsA, NonLocalsA),
        GoalB = term_primitive(PolyB, LocalsB, NonLocalsB)
    -> 
        Poly = polyhedron.intersection(PolyA, PolyB),
        Locals = LocalsA ++ LocalsB,
        NonLocals = NonLocalsA ++ NonLocalsB,
        Goal = term_primitive(Poly, Locals, NonLocals)
    ;
        unexpected(this_file, "intersect_primitives called with "
            ++ "non-primitive goals.")
    ).     

    % We end up with `empty' primitives by abstracting unifications
    % that involve variables that have zero size.
    %
:- pred is_empty_primitive(abstract_goal::in) is semidet.

is_empty_primitive(term_primitive(Poly, _, _)) :-
    polyhedron.is_universe(Poly).  

    % We end up with `empty' conjunctions by abstracting conjunctions
    % that involve variables that have zero size.
    %
:- pred is_empty_conj(abstract_goal::in) is semidet.

is_empty_conj(term_conj([], _, _)).

    % We end up with `empty' disjunctions by abstracting disjunctions
    % that involve variables that have zero size.
    %
:- pred is_empty_disj(abstract_goal::in) is semidet.

is_empty_disj(term_disj([], _, _, _)).

%-----------------------------------------------------------------------------%
%
% Code for dealing with different types of recursion.
%

combine_recursion_types(none,        none)        = none.
combine_recursion_types(none,        direct_only) = direct_only.
combine_recursion_types(none,        mutual_only) = mutual_only.
combine_recursion_types(none,        both)        = both.
combine_recursion_types(direct_only, none)        = direct_only.
combine_recursion_types(direct_only, direct_only) = direct_only.
combine_recursion_types(direct_only, mutual_only) = both.
combine_recursion_types(direct_only, both)        = both.
combine_recursion_types(mutual_only, none)        = mutual_only.
combine_recursion_types(mutual_only, direct_only) = both.
combine_recursion_types(mutual_only, mutual_only) = mutual_only.
combine_recursion_types(mutual_only, both)        = both.
combine_recursion_types(both,        none)        = both.
combine_recursion_types(both,        direct_only) = both.
combine_recursion_types(both,        mutual_only) = both.
combine_recursion_types(both,        both)        = both.

combine_primitive_goals(GoalA, GoalB) = Goal :-
    (
        GoalA = term_primitive(PolyA, LocalsA, NonLocalsA),
        GoalB = term_primitive(PolyB, LocalsB, NonLocalsB)
    ->  
        Poly      = polyhedron.intersection(PolyA, PolyB),  
        Locals    = LocalsA ++ LocalsB,
        NonLocals = NonLocalsA ++ NonLocalsB, 
        Goal      = term_primitive(Poly, Locals, NonLocals)
    ;
        unexpected(this_file, 
            "non-primitive goals passed to combine_primitive_goals")
    ).

%-----------------------------------------------------------------------------%
%
% Predicates for printing out the abstract data structure.
% (These are for debugging only)
%

dump_abstract_scc(SCC, Module, !IO) :-
    dump_abstract_scc(SCC, 0, Module, !IO).

dump_abstract_scc(SCC, Indent, Module, !IO) :-
    list.foldl((pred(Proc::in, !.IO::di, !:IO::uo) is det :-
            dump_abstract_proc(Proc, Indent, Module, !IO)
        ), SCC, !IO).

dump_abstract_proc(Proc, Indent, Module, !IO) :-
    Proc = abstract_proc(AbstractPPId, _, _, _, HeadVars, _ ,_,
        Body, _, Varset, _, _),
    indent_line(Indent, !IO),
    AbstractPPId = real(PPId),
    hlds_out.write_pred_proc_id(Module, PPId, !IO),
    io.write_string(" : [", !IO),
    WriteHeadVars = (pred(Var::in, !.IO::di, !:IO::uo) is det :-
        varset.lookup_name(Varset, Var, VarName),
        io.format(VarName ++ "[%d]", [i(term.var_id(Var))], !IO)
    ),
    io.write_list(HeadVars, ", ", WriteHeadVars, !IO), 
    io.write_string(" ] :- \n", !IO),
    dump_abstract_goal(Module, Varset, Indent + 1, Body, !IO).

:- func recursion_type_to_string(recursion_type) = string.

recursion_type_to_string(none)        = "none".
recursion_type_to_string(direct_only) = "direct recursion only".
recursion_type_to_string(mutual_only) = "mutual recursion only".
recursion_type_to_string(both)        = "mutual and direct recursion".

:- pred dump_abstract_disjuncts(abstract_goals::in, size_varset::in, int::in,
    module_info::in, io::di, io::uo) is det.

dump_abstract_disjuncts([], _, _, _, !IO).
dump_abstract_disjuncts([Goal | Goals], Varset, Indent, Module, !IO) :-
    dump_abstract_goal(Module, Varset, Indent + 1, Goal, !IO),
    (
        Goals = [_ | _],
        indent_line(Indent, !IO),
        io.write_string(";\n", !IO)
    ;   
        Goals = []
    ),
    dump_abstract_disjuncts(Goals, Varset, Indent, Module, !IO).

dump_abstract_goal(Module, Varset, Indent,
        term_disj(Goals, Size, Locals, NonLocals), !IO) :-
    indent_line(Indent, !IO),
    io.format("disj[%d](\n", [i(Size)], !IO),
    dump_abstract_disjuncts(Goals, Varset, Indent, Module, !IO),
    WriteVars = (pred(Var::in, !.IO::di, !:IO::uo) is det :-
        varset.lookup_name(Varset, Var, VarName),
        io.write_string(VarName, !IO)
    ),
    indent_line(Indent, !IO),
    io.write_string(" Locals: ", !IO),
    io.write_list(Locals, ", ", WriteVars, !IO), 
    io.nl(!IO),
    indent_line(Indent, !IO),
    io.write_string(" Non-Locals: ", !IO),
    io.write_list(NonLocals, ", ", WriteVars, !IO), 
    io.nl(!IO),
    indent_line(Indent, !IO),
    io.write_string(")\n", !IO).

dump_abstract_goal(Module, Varset, Indent, term_conj(Goals, Locals, NonLocals),
        !IO)  :-
    indent_line(Indent, !IO),
    io.write_string("conj(\n", !IO),
    list.foldl(dump_abstract_goal(Module, Varset, Indent + 1), Goals, !IO),
    WriteVars = (pred(Var::in, !.IO::di, !:IO::uo) is det :-
        varset.lookup_name(Varset, Var, VarName),
        io.write_string(VarName, !IO)
    ),
    indent_line(Indent, !IO),
    io.write_string(" Locals: ", !IO),
    io.write_list(Locals, ", ", WriteVars, !IO), 
    io.nl(!IO),
    indent_line(Indent, !IO),
    io.write_string(" Non-Locals: ", !IO),
    io.write_list(NonLocals, ", ", WriteVars, !IO), 
    io.nl(!IO),
    indent_line(Indent, !IO),
    io.write_string(")\n", !IO).

dump_abstract_goal(Module, Varset, Indent,
        term_call(PPId0, _, CallVars, _, _, _, CallPoly), !IO) :-
    indent_line(Indent, !IO),
    io.write_string("call: ", !IO),
    PPId0 = real(PPId),
    hlds_out.write_pred_proc_id(Module, PPId, !IO),
    io.write_string(" : [", !IO),
    WriteVars = (pred(Var::in, !.IO::di, !:IO::uo) is det :-
        varset.lookup_name(Varset, Var, VarName),
        io.write_string(VarName, !IO)
    ),
    io.write_list(CallVars, ", ", WriteVars, !IO), 
    io.write_string("]\n", !IO),
    indent_line(Indent, !IO),
    io.write_string("Other call constraints:[\n", !IO),
    polyhedron.write_polyhedron(CallPoly, Varset, !IO),
    indent_line(Indent, !IO),
    io.write_string("]\n", !IO).
    
dump_abstract_goal(_, Varset, Indent, term_primitive(Poly, _, _), !IO) :-
    indent_line(Indent, !IO),
    io.write_string("[\n", !IO),
    polyhedron.write_polyhedron(Poly, Varset, !IO),
    indent_line(Indent, !IO),
    io.write_string("]\n", !IO).

%-----------------------------------------------------------------------------%
%
% Predicates for simplifying conjuncts.
%

% XXX Make this part of the other AR simplification predicates.  

simplify_conjuncts(Goals0) = Goals :-
    simplify_conjuncts(Goals0, Goals).

:- pred simplify_conjuncts(abstract_goals::in, abstract_goals::out) is det.

simplify_conjuncts(Goals0, Goals) :-
    ( 
        Goals0 = []
    ->
        Goals = []
    ;   
        Goals0 = [Goal]
    ->
        Goals = [Goal]
    ;   
        % If the list of conjuncts starts with two primitives
        % join them together into a single primitive.
        Goals0 = [GoalA, GoalB | OtherGoals],
        GoalA  = term_primitive(PolyA,  LocalsA, NonLocalsA),
        GoalB  = term_primitive(PolyB,  LocalsB, NonLocalsB)
    ->  
        Poly = polyhedron.intersection(PolyA, PolyB),
        Locals = LocalsA ++ LocalsB,
        NonLocals = NonLocalsA ++ NonLocalsB, 
        Goal = term_primitive(Poly, Locals, NonLocals),
        Goals1 = [Goal | OtherGoals],
        simplify_conjuncts(Goals1, Goals)
    ;
        Goals = Goals0  
    ). 

%-----------------------------------------------------------------------------%
%
% Utility predicates.
%

:- pred indent_line(int::in, io::di, io::uo) is det.

indent_line(N, !IO) :- 
    ( if    N > 0
      then  io.write_string("  ", !IO), indent_line(N - 1, !IO)
      else  true    
    ).

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "term_constr_data.m".

%-----------------------------------------------------------------------------%
:- end_module transform_hlds.term_constr_data.
%-----------------------------------------------------------------------------%
