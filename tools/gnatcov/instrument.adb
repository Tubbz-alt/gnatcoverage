------------------------------------------------------------------------------
--                                                                          --
--                               GNATcoverage                               --
--                                                                          --
--                     Copyright (C) 2008-2018, AdaCore                     --
--                                                                          --
-- GNATcoverage is free software; you can redistribute it and/or modify it  --
-- under terms of the GNU General Public License as published by the  Free  --
-- Software  Foundation;  either version 3,  or (at your option) any later  --
-- version. This software is distributed in the hope that it will be useful --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

--  Source instrumentation

with Ada.Characters.Conversions; use Ada.Characters.Conversions;

with Langkit_Support.Slocs;   use Langkit_Support.Slocs;
with Langkit_Support.Symbols; use Langkit_Support.Symbols;
with Langkit_Support.Text;
with Libadalang.Analysis;     use Libadalang.Analysis;
with Libadalang.Common;       use Libadalang.Common;
--  with Libadalang.Lexer;        --  use Libadalang.Lexer;
with Libadalang.Sources;      use Libadalang.Sources;

with Namet; use Namet;
with Snames; use Snames;
with Types; use Types;
with Table;

with SC_Obligations; use SC_Obligations;

package body Instrument is

   Symbols : Symbol_Table := Create_Symbol_Table;
   --  Holder for name singletons

   Aspect_Dynamic_Predicate : constant Symbol_Type := Find
     (Symbols, Canonicalize ("Dynamic_Predicate").Symbol);
   Aspect_Invariant         : constant Symbol_Type := Find
     (Symbols, Canonicalize ("Invariant").Symbol);
   Aspect_Post              : constant Symbol_Type := Find
     (Symbols, Canonicalize ("Post").Symbol);
   Aspect_Postcondition     : constant Symbol_Type := Find
     (Symbols, Canonicalize ("Postcondition").Symbol);
   Aspect_Pre               : constant Symbol_Type := Find
     (Symbols, Canonicalize ("Pre").Symbol);
   Aspect_Precondition      : constant Symbol_Type := Find
     (Symbols, Canonicalize ("Precondition").Symbol);
   Aspect_Predicate         : constant Symbol_Type := Find
     (Symbols, Canonicalize ("Predicate").Symbol);
   Aspect_Static_Predicate  : constant Symbol_Type := Find
     (Symbols, Canonicalize ("Static_Predicate").Symbol);
   Aspect_Type_Invariant    : constant Symbol_Type := Find
     (Symbols, Canonicalize ("Type_Invariant").Symbol);

   function As_Name (Id : Identifier) return Name_Id;
   function As_Symbol (Id : Identifier) return Symbol_Type;
   --  Canonicalize Id and return a corresponding Name_Id/Symbol_Type

   function Pragma_Name (P : Pragma_Node) return Symbol_Type;
   --  Return a symbol from Symbols corresponding to the name of the given
   --  P pragma.

   function Aspect_Assoc_Name (A : Aspect_Assoc) return Symbol_Type;
   --  Return a symbol from Symbols corresponding to the name of the given
   --  A aspect association.

   --------------------------
   -- First-pass SCO table --
   --------------------------

   --  The Short_Circuit_And_Or pragma enables one to use AND and OR operators
   --  in source code while the ones used with booleans will be interpreted as
   --  their short circuit alternatives (AND THEN and OR ELSE). Thus, the true
   --  meaning of these operators is known only after the semantic analysis.

   --  However, decision SCOs include short circuit operators only. The SCO
   --  information generation pass must be done before expansion, hence before
   --  the semantic analysis. Because of this, the SCO information generation
   --  is done in two passes.

   --  The first one (SCO_Record_Raw, before semantic analysis) completes the
   --  SCO_Raw_Table assuming all AND/OR operators are short circuit ones.
   --  Then, the semantic analysis determines which operators are promoted to
   --  short circuit ones. Finally, the second pass (SCO_Record_Filtered)
   --  translates the SCO_Raw_Table to SCO_Table, taking care of removing the
   --  remaining AND/OR operators and of adjusting decisions accordingly
   --  (splitting decisions, removing empty ones, etc.).

   type SCO_Generation_State_Type is (None, Raw, Filtered);
   SCO_Generation_State : SCO_Generation_State_Type := None;
   --  Keep track of the SCO generation state: this will prevent us from
   --  running some steps multiple times (the second pass has to be started
   --  from multiple places).

   type SCO_Table_Entry is record
      From : Source_Location := No_Source_Location;
      To   : Source_Location := No_Source_Location;
      C1   : Character       := ' ';
      C2   : Character       := ' ';
      Last : Boolean         := False;

      Pragma_Sloc : Source_Location := No_Source_Location;
      --  For the decision SCO of a pragma, or for the decision SCO of any
      --  expression nested in a pragma Debug/Assert/PPC, location of PRAGMA
      --  token (used for control of SCO output, value not recorded in ALI
      --  file). Similarly, for the decision SCO of an aspect, or for the
      --  decision SCO of any expression nested in an aspect, location of
      --  aspect identifier token.

      Pragma_Aspect_Name : Name_Id := Namet.No_Name;
      --  For the SCO for a pragma/aspect, gives the pragma/apsect name
   end record;

   package SCO_Raw_Table is new Table.Table
     (Table_Component_Type => SCO_Table_Entry,
      Table_Index_Type     => Nat,
      Table_Low_Bound      => 1,
      Table_Initial        => 500,
      Table_Increment      => 300,
      Table_Name           => "Raw_Table");

   procedure Append_SCO
     (C1, C2             : Character;
      From, To           : Source_Location;
      Last               : Boolean;
      Pragma_Aspect_Name : Symbol_Type := null) is null;
   --  ???

   Current_Pragma_Sloc : Source_Location := No_Source_Location;
   --  Start location for the currently enclosing pragma, if any

   type Dominant_Info is record
      K : Character;
      --  F/T/S/E for a valid dominance marker, or ' ' for no dominant

      N : Ada_Node;
      --  Node providing the Sloc(s) for the dominance marker
   end record;
   No_Dominant : constant Dominant_Info := (' ', No_Ada_Node);

   function Sloc (N : Ada_Node'Class) return Source_Location is
     (Start_Sloc (N.Sloc_Range));

   procedure Traverse_Declarations_Or_Statements
     (L : Ada_Node_List;
      D : Dominant_Info := No_Dominant;
      P : Ada_Node      := No_Ada_Node);
   --  Process L, a list of statements or declarations dominated by D. If P is
   --  present, it is processed as though it had been prepended to L.

   function Traverse_Declarations_Or_Statements
     (L : Ada_Node_List;
      D : Dominant_Info := No_Dominant;
      P : Ada_Node      := No_Ada_Node) return Dominant_Info;
   --  Same as above, and returns dominant information corresponding to the
   --  last node with SCO in L.

   --  The following Traverse_* routines perform appropriate calls to
   --  Traverse_Declarations_Or_Statements to traverse specific node kinds.
   --  Parameter D, when present, indicates the dominant of the first
   --  declaration or statement within N.

   --  Why is Traverse_Sync_Definition commented specifically, whereas
   --  the others are not???

   procedure Traverse_Generic_Package_Declaration (N : Generic_Package_Decl);

   procedure Traverse_Handled_Statement_Sequence
     (N : Handled_Stmts;
      D : Dominant_Info := No_Dominant);

   procedure Traverse_Package_Body (N : Package_Body);

   procedure Traverse_Package_Declaration
     (N : Base_Package_Decl;
      D : Dominant_Info := No_Dominant);

   procedure Traverse_Subprogram_Or_Task_Body
     (N : Ada_Node;
      D : Dominant_Info := No_Dominant);

   procedure Traverse_Sync_Definition (N : Ada_Node);
   --  Traverse a protected definition or task definition

   --  Note regarding traversals: In a few cases where an Alternatives list is
   --  involved, pragmas such as "pragma Page" may show up before the first
   --  alternative. We skip them because we're out of statement or declaration
   --  context, so these can't be pragmas of interest for SCO purposes, and
   --  the regular alternative processing typically involves attribute queries
   --  which aren't valid for a pragma.

   procedure Process_Decisions
     (N           : Ada_Node'Class;
      T           : Character;
      Pragma_Sloc : Source_Location);
   --  If N is Empty, has no effect. Otherwise scans the tree for the node N,
   --  to output any decisions it contains. T is one of IEGPWX (for context of
   --  expression: if/exit when/entry guard/pragma/while/expression). If T is
   --  other than X, the node N is the if expression involved, and a decision
   --  is always present (at the very least a simple decision is present at the
   --  top level).

   --------------------------
   -- Internal Subprograms --
   --------------------------

   function Has_Decision (T : Ada_Node'Class) return Boolean;
   --  T is the node for a subtree. Returns True if any (sub)expression in T
   --  contains a nested decision (i.e. either is a logical operator, or
   --  contains a logical operator in its subtree).

   function Operator (N : Expr) return Op;
   --  Return the operator node of an unary or binary expression, or No_Op if
   --  not an operator.

   function Is_Logical_Operator (N : Ada_Node'Class) return Tristate;
   --  N is the node for a subexpression. This procedure determines whether N
   --  is a logical operator: True for short circuit conditions, Unknown for OR
   --  and AND (the Short_Circuit_And_Or pragma may be used) and False
   --  otherwise. Note that in cases where True is returned, callers assume
   --  Nkind (N) in N_Op.

   -----------------------------------------
   -- Traverse_Declarations_Or_Statements --
   -----------------------------------------

   --  Tables used by Traverse_Declarations_Or_Statements for temporarily
   --  holding statement and decision entries. These are declared globally
   --  since they are shared by recursive calls to this procedure.

   type SC_Entry is record
      N    : Ada_Node;
      From : Source_Location;
      To   : Source_Location;
      Typ  : Character;
   end record;
   --  Used to store a single entry in the following table, From:To represents
   --  the range of entries in the CS line entry, and typ is the type, with
   --  space meaning that no type letter will accompany the entry.

   package SC is new Table.Table
     (Table_Component_Type => SC_Entry,
      Table_Index_Type     => Nat,
      Table_Low_Bound      => 1,
      Table_Initial        => 1000,
      Table_Increment      => 200,
      Table_Name           => "SCO_SC");
   --  Used to store statement components for a CS entry to be output as a
   --  result of the call to this procedure. SC.Last is the last entry stored,
   --  so the current statement sequence is represented by SC_Array (SC_First
   --  .. SC.Last), where SC_First is saved on entry to each recursive call to
   --  the routine.
   --
   --  Extend_Statement_Sequence adds an entry to this array, and then
   --  Set_Statement_Entry clears the entries starting with SC_First, copying
   --  these entries to the main SCO output table. The reason that we do the
   --  temporary caching of results in this array is that we want the SCO table
   --  entries for a given CS line to be contiguous, and the processing may
   --  output intermediate entries such as decision entries.

   type SD_Entry is record
      Nod : Ada_Node;
      Typ : Character;
      Plo : Source_Location;
   end record;
   --  Used to store a single entry in the following table. Nod is the node to
   --  be searched for decisions for the case of Process_Decisions_Defer with a
   --  node argument (with Lst set to No_Ada_Node. Lst is the list to be
   --  searched for decisions for the case of Process_Decisions_Defer with a
   --  List argument (in which case Nod is set to No_Ada_Node). Plo is the sloc
   --  of the enclosing pragma, if any.

   package SD is new Table.Table
     (Table_Component_Type => SD_Entry,
      Table_Index_Type     => Nat,
      Table_Low_Bound      => 1,
      Table_Initial        => 1000,
      Table_Increment      => 200,
      Table_Name           => "SCO_SD");
   --  Used to store possible decision information. Instead of calling the
   --  Process_Decisions procedures directly, we call Process_Decisions_Defer,
   --  which simply stores the arguments in this table. Then when we clear
   --  out a statement sequence using Set_Statement_Entry, after generating
   --  the CS lines for the statements, the entries in this table result in
   --  calls to Process_Decision. The reason for doing things this way is to
   --  ensure that decisions are output after the CS line for the statements
   --  in which the decisions occur.

   procedure Traverse_Declarations_Or_Statements
     (L : Ada_Node_List;
      D : Dominant_Info := No_Dominant;
      P : Ada_Node      := No_Ada_Node)
   is
      Discard_Dom : Dominant_Info;
      pragma Warnings (Off, Discard_Dom);
   begin
      Discard_Dom := Traverse_Declarations_Or_Statements (L, D, P);
   end Traverse_Declarations_Or_Statements;

   function Traverse_Declarations_Or_Statements
     (L : Ada_Node_List;
      D : Dominant_Info := No_Dominant;
      P : Ada_Node      := No_Ada_Node) return Dominant_Info
   is
      Current_Dominant : Dominant_Info := D;
      --  Dominance information for the current basic block

      Current_Test : Ada_Node;
      --  Conditional node (N_If_Statement or N_Elsiif being processed

      SC_First : constant Nat := SC.Last + 1;
      SD_First : constant Nat := SD.Last + 1;
      --  Record first entries used in SC/SD at this recursive level

      procedure Extend_Statement_Sequence
        (N : Ada_Node'Class; Typ : Character);
      --  Extend the current statement sequence to encompass the node N. Typ is
      --  the letter that identifies the type of statement/declaration that is
      --  being added to the sequence.

      procedure Process_Decisions_Defer (N : Ada_Node'Class; T : Character);
      pragma Inline (Process_Decisions_Defer);
      --  This routine is logically the same as Process_Decisions, except that
      --  the arguments are saved in the SD table for later processing when
      --  Set_Statement_Entry is called, which goes through the saved entries
      --  making the corresponding calls to Process_Decision. Note: the
      --  enclosing statement must have already been added to the current
      --  statement sequence, so that nested decisions are properly
      --  identified as such.

      procedure Set_Statement_Entry;
      --  Output CS entries for all statements saved in table SC, and end the
      --  current CS sequence. Then output entries for all decisions nested in
      --  these statements, which have been deferred so far.

      procedure Traverse_One (N : Ada_Node);
      --  Traverse one declaration or statement

      procedure Traverse_Aspects (N : Ada_Node'Class);
      --  Helper for Traverse_One: traverse N's aspect specifications

      procedure Traverse_Degenerate_Subprogram (N : Ada_Node'Class);
      --  Common code to handle null procedures and expression functions. Emit
      --  a SCO of the given Kind and N outside of the dominance flow.

      -------------------------------
      -- Extend_Statement_Sequence --
      -------------------------------

      procedure Extend_Statement_Sequence
        (N : Ada_Node'Class; Typ : Character)
      is
         SR      : constant Source_Location_Range := N.Sloc_Range;

         F       : constant Source_Location := Start_Sloc (SR);
         T       : Source_Location := End_Sloc (SR);
         --  Source location bounds used to produre a SCO statement. By
         --  default, this should cover the same source location range as N,
         --  however for nodes that can contain themselves other statements
         --  (for instance IN statements), we select an end bound that appear
         --  before the first nested statement (see To_Node below).

         To_Node : Ada_Node := No_Ada_Node;
         --  In the case of simple statements, set to No_Ada_Node and unused.
         --  Othewrise, use F and this node's end sloc for the emitted
         --  statement source location ranage.

      begin
         case Kind (N) is
            when Ada_Accept_Stmt =>
               --  Make the SCO statement span until the parameters closing
               --  parent (if present). If there is no parameter, then use the
               --  entry index. If there is no entry index, fallback to the
               --  entry name.
               declare
                  Stmt : constant Accept_Stmt := N.As_Accept_Stmt;
               begin
                  if not Stmt.F_Params.Is_Null then
                     To_Node := Stmt.F_Params.As_Ada_Node;

                  elsif not Stmt.F_Entry_Index_Expr.Is_Null then
                     To_Node := Stmt.F_Entry_Index_Expr.As_Ada_Node;

                  else
                     To_Node := Stmt.F_Name.As_Ada_Node;
                  end if;
               end;

            when Ada_Case_Stmt =>
               To_Node := N.As_Case_Stmt.F_Expr.As_Ada_Node;

            when Ada_Elsif_Stmt_Part =>
               To_Node := N.As_Elsif_Stmt_Part.F_Cond_Expr.As_Ada_Node;

            when Ada_If_Stmt =>
               To_Node := N.As_If_Stmt.F_Cond_Expr.As_Ada_Node;

            when Ada_Extended_Return_Stmt =>
               To_Node := N.As_Extended_Return_Stmt.F_Decl.As_Ada_Node;

            when Ada_Base_Loop_Stmt =>
               To_Node := N.As_Base_Loop_Stmt.F_Spec.As_Ada_Node;

            when Ada_Select_Stmt
               | Ada_Single_Protected_Decl
               | Ada_Single_Task_Decl
            =>
               T := F;

            when Ada_Protected_Type_Decl
               | Ada_Task_Type_Decl
            =>
               declare
                  Decl : constant Protected_Type_Decl :=
                     N.As_Protected_Type_Decl;
               begin
                  if not Decl.F_Aspects.Is_Null then
                     To_Node := Decl.F_Aspects.As_Ada_Node;

                  elsif not Decl.F_Discriminants.Is_Null then
                     To_Node := Decl.F_Discriminants.As_Ada_Node;

                  else
                     To_Node := Decl.F_Name.As_Ada_Node;
                  end if;
               end;

            when Ada_Expr =>
               To_Node := N.As_Ada_Node;

            when others =>
               null;
         end case;

         if not To_Node.Is_Null then
            T := End_Sloc (To_Node.Sloc_Range);
         end if;

         SC.Append ((Ada_Node (N), F, T, Typ));
      end Extend_Statement_Sequence;

      -----------------------------
      -- Process_Decisions_Defer --
      -----------------------------

      procedure Process_Decisions_Defer (N : Ada_Node'Class; T : Character) is
      begin
         SD.Append ((N.As_Ada_Node, T, Current_Pragma_Sloc));
      end Process_Decisions_Defer;

      -------------------------
      -- Set_Statement_Entry --
      -------------------------

      procedure Set_Statement_Entry is
         SC_Last : constant Int := SC.Last;
         SD_Last : constant Int := SD.Last;

      begin
         --  Output statement entries from saved entries in SC table

         for J in SC_First .. SC_Last loop

            --  If there is a pending dominant for this statement sequence,
            --  emit a SCO for it.

            if J = SC_First and then Current_Dominant /= No_Dominant then
               declare
                  SR   : constant Source_Location_Range :=
                     Current_Dominant.N.Sloc_Range;
                  From : constant Source_Location := Start_Sloc (SR);
                  To   : Source_Location := End_Sloc (SR);

               begin
                  if Current_Dominant.K /= 'E' then
                     To := No_Source_Location;
                  end if;

                  Append_SCO
                    (C1                 => '>',
                     C2                 => Current_Dominant.K,
                     From               => From,
                     To                 => To,
                     Last               => False,
                     Pragma_Aspect_Name => null);
               end;
            end if;

            declare
               SCE                : SC_Entry renames SC.Table (J);
               Pragma_Aspect_Name : Symbol_Type := null;

            begin
               if SCE.Typ = 'P' then
                  Pragma_Aspect_Name := Pragma_Name (SCE.N.As_Pragma_Node);
               end if;

               Append_SCO
                 (C1                 => 'S',
                  C2                 => SCE.Typ,
                  From               => SCE.From,
                  To                 => SCE.To,
                  Last               => (J = SC_Last),
                  Pragma_Aspect_Name => Pragma_Aspect_Name);
            end;
         end loop;

         --  Last statement of basic block, if present, becomes new current
         --  dominant.

         if SC_Last >= SC_First then
            Current_Dominant := ('S', SC.Table (SC_Last).N);
         end if;

         --  Clear out used section of SC table

         SC.Set_Last (SC_First - 1);

         --  Output any embedded decisions

         for J in SD_First .. SD_Last loop
            declare
               SDE : SD_Entry renames SD.Table (J);

            begin
               Process_Decisions (SDE.Nod, SDE.Typ, SDE.Plo);
            end;
         end loop;

         --  Clear out used section of SD table

         SD.Set_Last (SD_First - 1);
      end Set_Statement_Entry;

      ----------------------
      -- Traverse_Aspects --
      ----------------------

      procedure Traverse_Aspects (N : Ada_Node'Class) is
         AS : constant Aspect_Spec :=
           (if N.Kind in Ada_Basic_Decl
            then N.As_Basic_Decl.P_Node_Aspects
            else No_Aspect_Spec);
         --  If there are any nodes other that Base_Decl that may have aspects
         --  then this will need to be adjusted???

         AL : constant Aspect_Assoc_List := AS.F_Aspect_Assocs;
         AN : Aspect_Assoc;
         AE : Expr;
         C1 : Character;

      begin
         for I in 1 .. AL.Children_Count loop
            AN := AL.Child (I).As_Aspect_Assoc;
            AE := AN.F_Expr;

            C1 := ASCII.NUL;

            if Aspect_Assoc_Name (AN) in Aspect_Dynamic_Predicate
                                       | Aspect_Invariant
                                       | Aspect_Post
                                       | Aspect_Postcondition
                                       | Aspect_Pre
                                       | Aspect_Precondition
                                       | Aspect_Predicate
                                       | Aspect_Static_Predicate
                                       | Aspect_Type_Invariant
            then
               C1 := 'A';

            else
               --  Other aspects: just process any decision nested in the
               --  aspect expression.

               if Has_Decision (AE) then
                  C1 := 'X';
               end if;
            end if;

            if C1 /= ASCII.NUL then
               pragma Assert (Current_Pragma_Sloc = No_Source_Location);

               if C1 = 'A' then
                  Current_Pragma_Sloc := Start_Sloc (AN.Sloc_Range);
               end if;

               Process_Decisions_Defer (AE, C1);

               Current_Pragma_Sloc := No_Source_Location;
            end if;
         end loop;
      end Traverse_Aspects;

      ------------------------------------
      -- Traverse_Degenerate_Subprogram --
      ------------------------------------

      procedure Traverse_Degenerate_Subprogram (N : Ada_Node'Class) is
      begin
         --  Complete current sequence of statements

         Set_Statement_Entry;

         declare
            Saved_Dominant : constant Dominant_Info := Current_Dominant;
            --  Save last statement in current sequence as dominant

         begin
            --  Output statement SCO for degenerate subprogram body (null
            --  statement or freestanding expression) outside of the dominance
            --  chain.

            Current_Dominant := No_Dominant;
            Extend_Statement_Sequence (N, Typ => ' ');

            --  For the case of an expression-function, collect decisions
            --  embedded in the expression now.

            if N.Kind in Ada_Expr then
               Process_Decisions_Defer (N, 'X');
            end if;

            Set_Statement_Entry;

            --  Restore current dominant information designating last statement
            --  in previous sequence (i.e. make the dominance chain skip over
            --  the degenerate body).

            Current_Dominant := Saved_Dominant;
         end;
      end Traverse_Degenerate_Subprogram;

      ------------------
      -- Traverse_One --
      ------------------

      procedure Traverse_One (N : Ada_Node) is
      begin
         --  Initialize or extend current statement sequence. Note that for
         --  special cases such as IF and Case statements we will modify
         --  the range to exclude internal statements that should not be
         --  counted as part of the current statement sequence.

         case N.Kind is

            --  Package declaration

            when Ada_Package_Decl =>
               Set_Statement_Entry;
               Traverse_Package_Declaration
                 (N.As_Base_Package_Decl, Current_Dominant);

            --  Generic package declaration

            when Ada_Generic_Package_Decl =>
               Set_Statement_Entry;
               Traverse_Generic_Package_Declaration
                 (N.As_Generic_Package_Decl);

            --  Package body

            when Ada_Package_Body =>
               Set_Statement_Entry;
               Traverse_Package_Body (N.As_Package_Body);

            --  Subprogram declaration or subprogram body stub

            when Ada_Expr_Function
               | Ada_Subp_Body_Stub
               | Ada_Subp_Decl
            =>
               declare
                  Spec : constant Subp_Spec :=
                    As_Subp_Spec (As_Basic_Decl (N).P_Subp_Spec_Or_Null);
               begin
                  Process_Decisions_Defer (Spec.F_Subp_Params, 'X');

                  --  Case of a null procedure: generate SCO for fictitious
                  --  NULL statement located at the NULL keyword in the
                  --  procedure specification.

                  if N.Kind = Ada_Null_Subp_Decl
                    and then Spec.F_Subp_Kind.Kind = Ada_Subp_Kind_Procedure
                  then
                     --  Traverse_Degenerate_Subprogram
                     --    (Null_Statement (Spec));
                     --  LAL??? No such fictitious node. But it doesn't really
                     --  matter, just pass Spec to provide the sloc.
                     Traverse_Degenerate_Subprogram (Spec);

                  --  Case of an expression function: generate a statement SCO
                  --  for the expression (and then decision SCOs for any nested
                  --  decisions).

                  elsif N.Kind = Ada_Expr_Function then
                     Traverse_Degenerate_Subprogram
                       (N.As_Expr_Function.F_Expr);
                  end if;
               end;

            --  Entry declaration

            when Ada_Entry_Decl =>
               Process_Decisions_Defer
                 (As_Entry_Decl (N).F_Spec.F_Entry_Params, 'X');

            --  Generic subprogram declaration

            when Ada_Generic_Subp_Decl =>
               declare
                  GSD : constant Generic_Subp_Decl := As_Generic_Subp_Decl (N);
               begin
                  Process_Decisions_Defer
                    (GSD.F_Formal_Part.F_Decls, 'X');
                  Process_Decisions_Defer
                    (GSD.F_Subp_Decl.F_Subp_Spec.F_Subp_Params, 'X');
               end;

            --  Task or subprogram body

            when Ada_Subp_Body
               | Ada_Task_Body
            =>
               Set_Statement_Entry;
               Traverse_Subprogram_Or_Task_Body (N);

            --  Entry body

            when Ada_Entry_Body =>
               declare
                  Cond : constant Expr := As_Entry_Body (N).F_Barrier;

                  Inner_Dominant : Dominant_Info := No_Dominant;

               begin
                  Set_Statement_Entry;

                  if not Cond.Is_Null then
                     Process_Decisions_Defer (Cond, 'G');

                     --  For an entry body with a barrier, the entry body
                     --  is dominanted by a True evaluation of the barrier.

                     Inner_Dominant := ('T', N);
                  end if;

                  Traverse_Subprogram_Or_Task_Body (N, Inner_Dominant);
               end;

            --  Protected body

            when Ada_Protected_Body =>
               Set_Statement_Entry;
               Traverse_Declarations_Or_Statements
                 (As_Protected_Body (N).F_Decls.F_Decls);

            --  Exit statement, which is an exit statement in the SCO sense,
            --  so it is included in the current statement sequence, but
            --  then it terminates this sequence. We also have to process
            --  any decisions in the exit statement expression.

            when Ada_Exit_Stmt =>
               Extend_Statement_Sequence (N, 'E');
               declare
                  Cond : constant Expr := As_Exit_Stmt (N).F_Cond_Expr;
               begin
                  Process_Decisions_Defer (Cond, 'E');
                  Set_Statement_Entry;

                  --  If condition is present, then following statement is
                  --  only executed if the condition evaluates to False.

                  if not Cond.Is_Null then
                     Current_Dominant := ('F', Ada_Node (Cond));
                  else
                     Current_Dominant := No_Dominant;
                  end if;
               end;

            --  Label, which breaks the current statement sequence, but the
            --  label itself is not included in the next statement sequence,
            --  since it generates no code.

            when Ada_Label =>
               Set_Statement_Entry;
               Current_Dominant := No_Dominant;

            --  Block statement, which breaks the current statement sequence

            when Ada_Decl_Block | Ada_Begin_Block =>
               Set_Statement_Entry;

               if N.Kind = Ada_Decl_Block then
                  --  The first statement in the handled sequence of statements
                  --  is dominated by the elaboration of the last declaration.

                  Current_Dominant := Traverse_Declarations_Or_Statements
                    (L => As_Decl_Block (N).F_Decls.F_Decls,
                     D => Current_Dominant);
               end if;

               Traverse_Handled_Statement_Sequence
                 (N => (case N.Kind is
                           when Ada_Decl_Block  => As_Decl_Block (N).F_Stmts,
                           when Ada_Begin_Block => As_Begin_Block (N).F_Stmts,
                           when others          => raise Program_Error),
                  D => Current_Dominant);

            --  If statement, which breaks the current statement sequence,
            --  but we include the condition in the current sequence.

            when Ada_If_Stmt =>
               Current_Test := N;
               Extend_Statement_Sequence (N, 'I');

               declare
                  If_N : constant If_Stmt := N.As_If_Stmt;
               begin
                  Process_Decisions_Defer (If_N.F_Cond_Expr, 'I');
                  Set_Statement_Entry;

                  --  Now we traverse the statements in the THEN part

                  Traverse_Declarations_Or_Statements
                    (L => If_N.F_Then_Stmts.As_Ada_Node_List,
                     D => ('T', N));

                  --  Loop through ELSIF parts if present

                  declare
                     Saved_Dominant : constant Dominant_Info :=
                       Current_Dominant;

                  begin
                     for J in 1 .. If_N.F_Alternatives.Children_Count loop
                        declare
                           Elif : constant Elsif_Stmt_Part :=
                             If_N.F_Alternatives
                               .Child (J).As_Elsif_Stmt_Part;
                        begin

                           --  An Elsif is executed only if the previous test
                           --  got a FALSE outcome.

                           Current_Dominant := ('F', Current_Test);

                           --  Now update current test information

                           Current_Test := Ada_Node (Elif);

                           --  We generate a statement sequence for the
                           --  construct "ELSIF condition", so that we have
                           --  a statement for the resulting decisions.

                           Extend_Statement_Sequence (Ada_Node (Elif), 'I');
                           Process_Decisions_Defer (Elif.F_Cond_Expr, 'I');
                           Set_Statement_Entry;

                           --  An ELSIF part is never guaranteed to have
                           --  been executed, following statements are only
                           --  dominated by the initial IF statement.

                           Current_Dominant := Saved_Dominant;

                           --  Traverse the statements in the ELSIF

                           Traverse_Declarations_Or_Statements
                             (L => Elif.F_Stmts.As_Ada_Node_List,
                              D => ('T', Ada_Node (Elif)));
                        end;
                     end loop;
                  end;

                  --  Finally traverse the ELSE statements if present

                  Traverse_Declarations_Or_Statements
                    (L => If_N.F_Else_Stmts.As_Ada_Node_List,
                     D => ('F', Current_Test));
               end;

            --  CASE statement, which breaks the current statement sequence,
            --  but we include the expression in the current sequence.

            when Ada_Case_Stmt =>
               Extend_Statement_Sequence (N, 'C');
               declare
                  Case_N : constant Case_Stmt := N.As_Case_Stmt;
               begin
                  Process_Decisions_Defer (Case_N.F_Expr, 'X');
                  Set_Statement_Entry;

                  --  Process case branches, all of which are dominated by the
                  --  CASE statement.

                  for J in 1 .. Case_N.F_Alternatives.Children_Count loop
                     declare
                        Alt : constant Case_Stmt_Alternative :=
                          Case_N.Child (J).As_Case_Stmt_Alternative;
                     begin
                        Traverse_Declarations_Or_Statements
                          (L => Alt.F_Stmts.As_Ada_Node_List,
                           D => Current_Dominant);
                     end;
                  end loop;
               end;

            --  ACCEPT statement

            when Ada_Accept_Stmt | Ada_Accept_Stmt_With_Stmts =>
               Extend_Statement_Sequence (N, 'A');
               Set_Statement_Entry;

               if N.Kind = Ada_Accept_Stmt_With_Stmts then
                  --  Process sequence of statements, dominant is the ACCEPT
                  --  statement.

                  Traverse_Handled_Statement_Sequence
                    (N => N.As_Accept_Stmt_With_Stmts.F_Stmts,
                     D => Current_Dominant);
               end if;

               --  SELECT statement

            --  (all 4 non-terminals: selective_accept, timed_entry_call,
            --  conditional_entry_call, and asynchronous_select).

            when Ada_Select_Stmt =>
               Extend_Statement_Sequence (N, 'S');
               Set_Statement_Entry;

               declare
                  Sel_N : constant Select_Stmt := As_Select_Stmt (N);
                  S_Dom : Dominant_Info;
               begin
                  for J in 1 .. Sel_N.F_Guards.Children_Count loop
                     declare
                        Alt : constant Select_When_Part :=
                          Sel_N.F_Guards.Child (J).As_Select_When_Part;
                        Guard : Expr;
                     begin
                        S_Dom := Current_Dominant;
                        Guard := Alt.F_Cond_Expr;

                        if not Guard.Is_Null then
                           Process_Decisions
                             (Guard,
                              'G',
                              Pragma_Sloc => No_Source_Location);
                           Current_Dominant := ('T', Ada_Node (Guard));
                        end if;

                        Traverse_Declarations_Or_Statements
                          (L => Alt.F_Stmts.As_Ada_Node_List,
                           D => Current_Dominant);

                        Current_Dominant := S_Dom;
                     end;
                  end loop;

                  Traverse_Declarations_Or_Statements
                    (L => Sel_N.F_Else_Stmts.As_Ada_Node_List,
                     D => Current_Dominant);
                  Traverse_Declarations_Or_Statements
                    (L => Sel_N.F_Abort_Stmts.As_Ada_Node_List,
                     D => Current_Dominant);
               end;

            when Ada_Terminate_Alternative =>

               --  It is dubious to emit a statement SCO for a TERMINATE
               --  alternative, since no code is actually executed if the
               --  alternative is selected -- the tasking runtime call just
               --  never returns???

               Extend_Statement_Sequence (N, ' ');
               Set_Statement_Entry;

            --  Unconditional exit points, which are included in the current
            --  statement sequence, but then terminate it

            when Ada_Goto_Stmt
               | Ada_Raise_Stmt
               | Ada_Requeue_Stmt
            =>
               Extend_Statement_Sequence (N, ' ');
               Set_Statement_Entry;
               Current_Dominant := No_Dominant;

            --  Simple return statement. which is an exit point, but we
            --  have to process the return expression for decisions.

            when Ada_Return_Stmt =>
               Extend_Statement_Sequence (N, ' ');
               Process_Decisions_Defer
                 (N.As_Return_Stmt.F_Return_Expr, 'X');
               Set_Statement_Entry;
               Current_Dominant := No_Dominant;

            --  Extended return statement

            when Ada_Extended_Return_Stmt =>
               Extend_Statement_Sequence (N, 'R');
               declare
                  ER_N : constant Extended_Return_Stmt :=
                    N.As_Extended_Return_Stmt;
               begin
                  Process_Decisions_Defer (ER_N.F_Decl, 'X');
                  Set_Statement_Entry;

                  Traverse_Handled_Statement_Sequence
                    (N => ER_N.F_Stmts,
                     D => Current_Dominant);
               end;
               Current_Dominant := No_Dominant;

            --  Loop ends the current statement sequence, but we include
            --  the iteration scheme if present in the current sequence.
            --  But the body of the loop starts a new sequence, since it
            --  may not be executed as part of the current sequence.

            when Ada_Base_Loop_Stmt =>
               declare
                  Loop_S         : constant Base_Loop_Stmt :=
                    N.As_Base_Loop_Stmt;
                  ISC            : constant Loop_Spec := Loop_S.F_Spec;
                  Inner_Dominant : Dominant_Info     := No_Dominant;

               begin
                  if not ISC.Is_Null then

                     --  If iteration scheme present, extend the current
                     --  statement sequence to include the iteration scheme
                     --  and process any decisions it contains.

                     --  WHILE loop

                     if ISC.Kind = Ada_While_Loop_Spec then
                        Extend_Statement_Sequence (N, 'W');
                        Process_Decisions_Defer
                          (ISC.As_While_Loop_Spec.F_Expr, 'W');

                        --  Set more specific dominant for inner statements
                        --  (the control sloc for the decision is that of
                        --  the WHILE token).

                        Inner_Dominant := ('T', Ada_Node (ISC));

                     --  FOR loop

                     else
                        Extend_Statement_Sequence (N, 'F');

                        declare
                           ISC_For : constant For_Loop_Spec :=
                             ISC.As_For_Loop_Spec;
                           For_Param : constant For_Loop_Var_Decl :=
                             ISC_For.F_Var_Decl;
                        begin
                           --  loop_parameter_specification case

                           if not For_Param.Is_Null then
                              Process_Decisions_Defer
                                (Ada_Node (For_Param), 'X');

                           --  iterator_specification case

                           else
                              Process_Decisions_Defer
                                (ISC_For.F_Loop_Type, 'X');
                              Process_Decisions_Defer
                                (ISC_For.F_Iter_Expr, 'X');
                           end if;
                        end;
                     end if;
                  end if;

                  Set_Statement_Entry;

                  if Inner_Dominant = No_Dominant then
                     Inner_Dominant := Current_Dominant;
                  end if;

                  Traverse_Declarations_Or_Statements
                    (L => Loop_S.F_Stmts.As_Ada_Node_List,
                     D => Inner_Dominant);
               end;

            --  Pragma

            when Ada_Pragma_Node =>

               --  Record sloc of pragma (pragmas don't nest)

               pragma Assert (Current_Pragma_Sloc = No_Source_Location);
               Current_Pragma_Sloc := Sloc (N);

               --  Processing depends on the kind of pragma

               declare
                  Prag_N    : constant Pragma_Node := N.As_Pragma_Node;
                  Prag_Args : constant Base_Assoc_List := Prag_N.F_Args;
                  Nam       : constant Name_Id := Name_Find (Prag_N.F_Id.Text);
                  Arg       : Positive := 1;
                  Typ       : Character;

               begin
                  case Nam is
                     when Name_Assert
                        | Name_Assert_And_Cut
                        | Name_Assume
                        | Name_Check
                        | Name_Loop_Invariant
                        | Name_Postcondition
                        | Name_Precondition
                     =>
                        --  For Assert/Check/Precondition/Postcondition, we
                        --  must generate a P entry for the decision. Note
                        --  that this is done unconditionally at this stage.
                        --  Output for disabled pragmas is suppressed later
                        --  on when we output the decision line in Put_SCOs,
                        --  depending on setting by Set_SCO_Pragma_Enabled.

                        if Nam = Name_Check then

                           --  Skip check name

                           Arg := 2;
                        end if;

                        Process_Decisions_Defer
                          (Prag_Args.Child (Arg), 'P');
                        Typ := 'p';

                        --  Pre/postconditions can be inherited so SCO should
                        --  never be deactivated???

                     when Name_Debug =>
                        if Prag_Args.Children_Count = 2 then

                           --  Case of a dyadic pragma Debug: first argument
                           --  is a P decision, any nested decision in the
                           --  second argument is an X decision.

                           Process_Decisions_Defer
                             (Prag_Args.Child (Arg), 'P');
                           Arg := 2;
                        end if;

                        Process_Decisions_Defer (Prag_Args.Child (Arg), 'X');
                        Typ := 'p';

                     --  For all other pragmas, we generate decision entries
                     --  for any embedded expressions, and the pragma is
                     --  never disabled.

                     --  Should generate P decisions (not X) for assertion
                     --  related pragmas: [Type_]Invariant,
                     --  [{Static,Dynamic}_]Predicate???

                     when others =>
                        Process_Decisions_Defer (N, 'X');
                        Typ := 'P';
                  end case;

                  --  Add statement SCO

                  Extend_Statement_Sequence (N, Typ);

                  Current_Pragma_Sloc := No_Source_Location;
               end;

            --  Object or named number declaration
            --  Generate a single SCO even if multiple defining identifiers
            --  are present.

            when Ada_Number_Decl
               | Ada_Object_Decl
            =>
               Extend_Statement_Sequence (N, 'o');

               if Has_Decision (N) then
                  Process_Decisions_Defer (N, 'X');
               end if;

            --  All other cases, which extend the current statement sequence
            --  but do not terminate it, even if they have nested decisions.

            when Ada_Protected_Type_Decl
               | Ada_Task_Type_Decl
            =>
               Extend_Statement_Sequence (N, 't');
               declare
                  Disc_N : constant Discriminant_Part :=
                    (case N.Kind is
                        when Ada_Protected_Type_Decl =>
                          N.As_Protected_Type_Decl.F_Discriminants,
                        when Ada_Task_Type_Decl      =>
                          N.As_Task_Type_Decl.F_Discriminants,
                        when others                  =>
                           raise Program_Error);
               begin
                  Process_Decisions_Defer (Disc_N, 'X');
               end;
               Set_Statement_Entry;

               Traverse_Sync_Definition (N);

            when Ada_Single_Protected_Decl
               | Ada_Single_Task_Decl
            =>
               Extend_Statement_Sequence (N, 'o');
               Set_Statement_Entry;

               Traverse_Sync_Definition (N);

            when others =>

               --  Determine required type character code, or ASCII.NUL if
               --  no SCO should be generated for this node.

               declare
                  Typ : Character;

               begin
                  case N.Kind is
                     when Ada_Base_Type_Decl =>
                        if N.Kind = Ada_Subtype_Decl then
                           Typ := 's';
                        else
                           Typ := 't';
                        end if;

                     --  Entity declaration nodes that may also be used
                     --  for entity renamings.

                     when Ada_Object_Decl | Ada_Exception_Decl =>
                        declare
                           Ren_N : constant Renaming_Clause :=
                             (case N.Kind is
                                 when Ada_Object_Decl    =>
                                   N.As_Object_Decl.F_Renaming_Clause,
                                 when Ada_Exception_Decl =>
                                   N.As_Exception_Decl.F_Renames,
                                 when others             =>
                                    raise Program_Error);
                        begin
                           if not Ren_N.Is_Null then
                              Typ := 'r';
                           else
                              Typ := 'd';
                           end if;
                        end;

                     when Ada_Package_Renaming_Decl   |
                          Ada_Subp_Renaming_Decl      |
                          Ada_Generic_Renaming_Decl   =>
                        Typ := 'r';

                     when Ada_Generic_Instantiation =>
                        Typ := 'i';

                     when Ada_Package_Body_Stub
                        | Ada_Protected_Body_Stub
                        | Ada_Aspect_Clause
                        | Ada_Task_Body_Stub
                        | Ada_Use_Package_Clause
                        | Ada_Use_Type_Clause
                     =>
                        Typ := ASCII.NUL;

                     when Ada_Call_Stmt =>
                        Typ := ' ';

                     when others =>
                        if N.Kind in Ada_Stmt then
                           Typ := ' ';
                        else
                           Typ := 'd';
                        end if;
                  end case;

                  if Typ /= ASCII.NUL then
                     Extend_Statement_Sequence (N, Typ);
                  end if;
               end;

               --  Process any embedded decisions

               if Has_Decision (N) then
                  Process_Decisions_Defer (N, 'X');
               end if;
         end case;

         --  Process aspects if present

         Traverse_Aspects (N);
      end Traverse_One;

   --  Start of processing for Traverse_Declarations_Or_Statements

   begin
      --  Process single prefixed node

      if not P.Is_Null then
         Traverse_One (P);
      end if;

      --  Loop through statements or declarations

      for J in 1 .. L.Children_Count loop
         declare
            N : constant Ada_Node := L.Child (J);
         begin
            Traverse_One (N);
         end;
      end loop;

      --  End sequence of statements and flush deferred decisions

      if not P.Is_Null or else L.Children_Count > 0 then
         Set_Statement_Entry;
      end if;

      return Current_Dominant;
   end Traverse_Declarations_Or_Statements;

   ------------------------------------------
   -- Traverse_Generic_Package_Declaration --
   ------------------------------------------

   procedure Traverse_Generic_Package_Declaration (N : Generic_Package_Decl) is
   begin
      Process_Decisions (N.F_Formal_Part, 'X', No_Source_Location);
      Traverse_Package_Declaration (N.F_Package_Decl.As_Base_Package_Decl);
   end Traverse_Generic_Package_Declaration;

   -----------------------------------------
   -- Traverse_Handled_Statement_Sequence --
   -----------------------------------------

   procedure Traverse_Handled_Statement_Sequence
     (N : Handled_Stmts;
      D : Dominant_Info := No_Dominant)
   is
   begin
      Traverse_Declarations_Or_Statements (N.F_Stmts.As_Ada_Node_List, D);

      for J in 1 .. N.F_Exceptions.Children_Count loop
         declare
            Handler : constant Ada_Node := N.F_Exceptions.Child (J);
         begin
            --  Note: the exceptions list can also contain pragmas

            if Handler.Kind = Ada_Exception_Handler then
               Traverse_Declarations_Or_Statements
                 (L => Handler.As_Exception_Handler.F_Stmts.As_Ada_Node_List,
                  D => ('E', Handler));
            end if;
         end;
      end loop;
   end Traverse_Handled_Statement_Sequence;

   ---------------------------
   -- Traverse_Package_Body --
   ---------------------------

   procedure Traverse_Package_Body (N : Package_Body) is
   begin
      --  The first statement in the handled sequence of statements is
      --  dominated by the elaboration of the last declaration.

      Traverse_Handled_Statement_Sequence
        (N => N.F_Stmts,
         D => Traverse_Declarations_Or_Statements (N.F_Decls.F_Decls));
   end Traverse_Package_Body;

   ----------------------------------
   -- Traverse_Package_Declaration --
   ----------------------------------

   procedure Traverse_Package_Declaration
     (N : Base_Package_Decl;
      D : Dominant_Info := No_Dominant)
   is
   begin
      --  First private declaration is dominated by last visible declaration

      Traverse_Declarations_Or_Statements
        (L => N.F_Private_Part.F_Decls,
         D => Traverse_Declarations_Or_Statements
                (N.F_Public_Part.F_Decls, D));
   end Traverse_Package_Declaration;

   ------------------------------
   -- Traverse_Sync_Definition --
   ------------------------------

   procedure Traverse_Sync_Definition (N : Ada_Node) is
      Dom_Info : Dominant_Info := ('S', N);
      --  The first declaration is dominated by the protected or task [type]
      --  declaration.

      Vis_Decl  : Public_Part;
      Priv_Decl : Private_Part;
      --  Visible and private declarations of the protected or task definition

   begin
      case N.Kind is
         when Ada_Protected_Type_Decl =>
            declare
               Prot_Def : constant Protected_Def :=
                 N.As_Protected_Type_Decl.F_Definition;
            begin
               Vis_Decl := Prot_Def.F_Public_Part;
               Priv_Decl := Prot_Def.F_Private_Part;
            end;

         when Ada_Single_Protected_Decl =>
            declare
               Prot_Def : constant Protected_Def :=
                 N.As_Single_Protected_Decl.F_Definition;
            begin
               Vis_Decl := Prot_Def.F_Public_Part;
               Priv_Decl := Prot_Def.F_Private_Part;
            end;

         when Ada_Single_Task_Decl =>
            declare
               T_Def : constant Task_Def :=
                 N.As_Single_Task_Decl.F_Task_Type.F_Definition;
            begin
               Vis_Decl := T_Def.F_Public_Part;
               Priv_Decl := T_Def.F_Private_Part;
            end;

         when Ada_Task_Type_Decl =>
            declare
               T_Def : constant Task_Def :=
                 N.As_Task_Type_Decl.F_Definition;
            begin
               Vis_Decl := T_Def.F_Public_Part;
               Priv_Decl := T_Def.F_Private_Part;
            end;

         when others =>
            raise Program_Error;
      end case;

      --  Vis_Decl and Priv_Decl may be Empty at least for empty task type
      --  declarations. Querying F_Decls is invalid in this case.

      if not Vis_Decl.Is_Null then
         Dom_Info := Traverse_Declarations_Or_Statements
           (L => Vis_Decl.F_Decls,
            D => Dom_Info);
      end if;

      if not Priv_Decl.Is_Null then
         --  If visible declarations are present, the first private declaration
         --  is dominated by the last visible declaration.

         Traverse_Declarations_Or_Statements
           (L => Priv_Decl.F_Decls,
            D => Dom_Info);
      end if;
   end Traverse_Sync_Definition;

   --------------------------------------
   -- Traverse_Subprogram_Or_Task_Body --
   --------------------------------------

   procedure Traverse_Subprogram_Or_Task_Body
     (N : Ada_Node;
      D : Dominant_Info := No_Dominant)
   is
      Decls    : Declarative_Part;
      HSS      : Handled_Stmts;
      Dom_Info : Dominant_Info    := D;

   begin
      case Kind (N) is
         when Ada_Subp_Body =>
            declare
               SBN : constant Subp_Body := N.As_Subp_Body;
            begin
               Decls := SBN.F_Decls;
               HSS   := SBN.F_Stmts;
            end;

         when Ada_Task_Body =>
            declare
               TBN : constant Task_Body := N.As_Task_Body;
            begin
               Decls := TBN.F_Decls;
               HSS   := TBN.F_Stmts;
            end;

         when others =>
            raise Program_Error;
      end case;

      --  If declarations are present, the first statement is dominated by the
      --  last declaration.

      Dom_Info := Traverse_Declarations_Or_Statements
                    (L => Decls.F_Decls, D => Dom_Info);

      Traverse_Handled_Statement_Sequence
        (N => HSS,
         D => Dom_Info);
   end Traverse_Subprogram_Or_Task_Body;

   -----------------------
   -- Process_Decisions --
   -----------------------

   procedure Process_Decisions
     (N           : Ada_Node'Class;
      T           : Character;
      Pragma_Sloc : Source_Location)
   is
      Mark : Nat;
      --  This is used to mark the location of a decision sequence in the SCO
      --  table. We use it for backing out a simple decision in an expression
      --  context that contains only NOT operators.

      Mark_Hash : Nat;
      --  Likewise for the putative SCO_Raw_Hash_Table entries: see below

      type Hash_Entry is record
         Sloc      : Source_Location;
         SCO_Index : Nat;
      end record;
      --  We must register all conditions/pragmas in SCO_Raw_Hash_Table.
      --  However we cannot register them in the same time we are adding the
      --  corresponding SCO entries to the raw table since we may discard them
      --  later on. So instead we put all putative conditions into Hash_Entries
      --  (see below) and register them once we are sure we keep them.
      --
      --  This data structure holds the conditions/pragmas to register in
      --  SCO_Raw_Hash_Table.

      package Hash_Entries is new Table.Table
        (Table_Component_Type => Hash_Entry,
         Table_Index_Type     => Nat,
         Table_Low_Bound      => 1,
         Table_Initial        => 10,
         Table_Increment      => 10,
         Table_Name           => "Hash_Entries");
      --  Hold temporarily (i.e. free'd before returning) the Hash_Entry before
      --  they are registered in SCO_Raw_Hash_Table.

      X_Not_Decision : Boolean;
      --  This flag keeps track of whether a decision sequence in the SCO table
      --  contains only NOT operators, and is for an expression context (T=X).
      --  The flag will be set False if T is other than X, or if an operator
      --  other than NOT is in the sequence.

      procedure Output_Decision_Operand (N : Expr);
      --  The node N is the top level logical operator of a decision, or it is
      --  one of the operands of a logical operator belonging to a single
      --  complex decision. This routine outputs the sequence of table entries
      --  corresponding to the node. Note that we do not process the sub-
      --  operands to look for further decisions, that processing is done in
      --  Process_Decision_Operand, because we can't get decisions mixed up in
      --  the global table. Call has no effect if N is Empty.

      procedure Output_Element (N : Ada_Node);
      --  Node N is an operand of a logical operator that is not itself a
      --  logical operator, or it is a simple decision. This routine outputs
      --  the table entry for the element, with C1 set to ' '. Last is set
      --  False, and an entry is made in the condition hash table.

      procedure Output_Header (T : Character);
      --  Outputs a decision header node. T is I/W/E/P for IF/WHILE/EXIT WHEN/
      --  PRAGMA, and 'X' for the expression case.

      procedure Process_Decision_Operand (N : Ada_Node);
      --  This is called on node N, the top level node of a decision, or on one
      --  of its operands or suboperands after generating the full output for
      --  the complex decision. It process the suboperands of the decision
      --  looking for nested decisions.

      function Process_Node (N : Ada_Node'Class) return Visit_Status;
      --  Processes one node in the traversal, looking for logical operators,
      --  and if one is found, outputs the appropriate table entries.

      -----------------------------
      -- Output_Decision_Operand --
      -----------------------------

      procedure Output_Decision_Operand (N : Expr) is
         C1 : Character;
         C2 : Character;
         --  C1 holds a character that identifies the operation while C2
         --  indicates whether we are sure (' ') or not ('?') this operation
         --  belongs to the decision. '?' entries will be filtered out in the
         --  second (SCO_Record_Filtered) pass.

         L, R : Expr;
         T    : Tristate;

         N_Op_Kind : constant Ada_Node_Kind_Type := Operator (N).Kind;
      begin
         if N.Is_Null then
            return;
         end if;

         T := Is_Logical_Operator (N);

         --  Logical operator

         if T /= False then
            if N_Op_Kind = Ada_Op_Not then
               C1 := '!';
               L := No_Expr;
               R := N.As_Un_Op.F_Expr;

            else
               declare
                  BN : constant Bin_Op := N.As_Bin_Op;
               begin
                  L := BN.F_Left;
                  R := BN.F_Right;
                  if N_Op_Kind in Ada_Op_Or | Ada_Op_Or_Else then
                     C1 := '|';
                  else pragma Assert (N_Op_Kind
                                      in Ada_Op_And | Ada_Op_And_Then);
                     C1 := '&';
                  end if;
               end;
            end if;

            if T = True then
               C2 := ' ';
            else
               C2 := '?';
            end if;

            Append_SCO
              (C1   => C1,
               C2   => C2,
               From => Sloc (N),
               To   => No_Source_Location,
               Last => False);

            Hash_Entries.Append ((Sloc (N), SCO_Raw_Table.Last));

            Output_Decision_Operand (L);
            Output_Decision_Operand (R);

         --  Not a logical operator

         else
            Output_Element (N.As_Ada_Node);
         end if;
      end Output_Decision_Operand;

      --------------------
      -- Output_Element --
      --------------------

      procedure Output_Element (N : Ada_Node) is
         N_SR : constant Source_Location_Range := N.Sloc_Range;
      begin
         Append_SCO
           (C1   => ' ',
            C2   => 'c',
            From => Start_Sloc (N_SR),
            To   => End_Sloc (N_SR),
            Last => False);
         Hash_Entries.Append ((Start_Sloc (N_SR), SCO_Raw_Table.Last));
      end Output_Element;

      -------------------
      -- Output_Header --
      -------------------

      procedure Output_Header (T : Character) is
         Loc : Source_Location := No_Source_Location;
         --  Node whose Sloc is used for the decision

         Nam : Name_Id := Namet.No_Name;
         --  For the case of an aspect, aspect name

      begin
         case T is
            when 'I' | 'E' | 'W' | 'a' | 'A' =>

               --  For IF, EXIT, WHILE, or aspects, the token SLOC is that of
               --  the parent of the expression.

               Loc := Sloc (Parent (N));

               if T = 'a' or else T = 'A' then
                  Nam := As_Name (N.Parent.Parent.As_Pragma_Node.F_Id);
               end if;

            when 'G' | 'P' =>

               --  For entry guard, the token sloc is from the N_Entry_Body.
               --  For PRAGMA, we must get the location from the pragma node.
               --  Argument N is the pragma argument, and we have to go up
               --  two levels (through the pragma argument association) to
               --  get to the pragma node itself. For the guard on a select
               --  alternative, we do not have access to the token location for
               --  the WHEN, so we use the first sloc of the condition itself
               --  (note: we use First_Sloc, not Sloc, because this is what is
               --  referenced by dominance markers).

               --  Doesn't this requirement of using First_Sloc need to be
               --  documented in the spec ???

               if Nkind_In (Parent (N), N_Accept_Alternative,
                                        N_Delay_Alternative,
                                        N_Terminate_Alternative)
               then
                  Loc := First_Sloc (N);
               else
                  Loc := Sloc (Parent (Parent (N)));
               end if;

            when 'X' =>

               --  For an expression, no Sloc

               null;

            --  No other possibilities

            when others =>
               raise Program_Error;
         end case;

         Append_SCO
           (C1                 => T,
            C2                 => ' ',
            From               => Loc,
            To                 => No_Location,
            Last               => False,
            Pragma_Aspect_Name => Nam);

         --  For an aspect specification, which will be rewritten into a
         --  pragma, enter a hash table entry now.

         if T = 'a' then
            Hash_Entries.Append ((Loc, SCO_Raw_Table.Last));
         end if;
      end Output_Header;

      ------------------------------
      -- Process_Decision_Operand --
      ------------------------------

      procedure Process_Decision_Operand (N : Ada_Node) is
      begin
         if Is_Logical_Operator (N) /= False then
            if N.Kind = Ada_Un_Op then
               Process_Decision_Operand (N.As_Un_Op.F_Expr);

            else
               Process_Decision_Operand (N.As_Bin_Op.F_Left);
               Process_Decision_Operand (N.As_Bin_Op.F_Right);
               X_Not_Decision := False;
            end if;

         else
            Process_Decisions (N, 'X', Pragma_Sloc);
         end if;
      end Process_Decision_Operand;

      ------------------
      -- Process_Node --
      ------------------

      function Process_Node (N : Ada_Node'Class) return Visit_Status is
      begin
         if Is_Logical_Operator (N) /= False then
            --  Logical operators, output table entries and then process
            --  operands recursively to deal with nested conditions.

            declare
               T : Character;

            begin
               --  If outer level, then type comes from call, otherwise it
               --  is more deeply nested and counts as X for expression.

               if N = Process_Decisions.N then
                  T := Process_Decisions.T;
               else
                  T := 'X';
               end if;

               --  Output header for sequence

               X_Not_Decision := T = 'X' and then Nkind (N) = Ada_Op_Not;
               Mark      := SCO_Raw_Table.Last;
               Mark_Hash := Hash_Entries.Last;
               Output_Header (T);

               --  Output the decision

               Output_Decision_Operand (N);

               --  If the decision was in an expression context (T = 'X')
               --  and contained only NOT operators, then we don't output
               --  it, so delete it.

               if X_Not_Decision then
                  SCO_Raw_Table.Set_Last (Mark);
                  Hash_Entries.Set_Last (Mark_Hash);

                  --  Otherwise, set Last in last table entry to mark end

               else
                  SCO_Raw_Table.Table (SCO_Raw_Table.Last).Last := True;
               end if;

               --  Process any embedded decisions

               Process_Decision_Operand (N);
               return Over;
            end;
         end if;

         --  Here for cases that are known to not be logical operators

         case N.Kind is
            --  Case expression

            --  Really hard to believe this is correct given the special
            --  handling for if expressions below ???

            when Ada_Case_Expression =>
               return Into; -- ???

            --  If expression, processed like an if statement

            when Ada_If_Expression =>
               declare
                  Cond : constant Ada_Node := First (Expressions (N));
                  Thnx : constant Ada_Node := Next (Cond);
                  Elsx : constant Ada_Node := Next (Thnx);

               begin
                  Process_Decisions (Cond, 'I', Pragma_Sloc);
                  Process_Decisions (Thnx, 'X', Pragma_Sloc);
                  Process_Decisions (Elsx, 'X', Pragma_Sloc);
                  return Over;
               end;

            --  All other cases, continue scan

            when others =>
               return Into;
         end case;
      end Process_Node;

      procedure Traverse is new Traverse_Proc (Process_Node);

   --  Start of processing for Process_Decisions

   begin
      if N.Is_Null then
         return;
      end if;

      Hash_Entries.Init;

      --  See if we have simple decision at outer level and if so then
      --  generate the decision entry for this simple decision. A simple
      --  decision is a boolean expression (which is not a logical operator
      --  or short circuit form) appearing as the operand of an IF, WHILE,
      --  EXIT WHEN, or special PRAGMA construct.

      if T /= 'X' and then Is_Logical_Operator (N) = False then
         Output_Header (T);
         Output_Element (N);

         --  Change Last in last table entry to True to mark end of
         --  sequence, which is this case is only one element long.

         SCO_Raw_Table.Table (SCO_Raw_Table.Last).Last := True;
      end if;

      Traverse (N);

      --  Now we have the definitive set of SCO entries, register them in the
      --  corresponding hash table.

      for J in 1 .. Hash_Entries.Last loop
         SCO_Raw_Hash_Table.Set
           (Hash_Entries.Table (J).Sloc,
            Hash_Entries.Table (J).SCO_Index);
      end loop;

      Hash_Entries.Free;
   end Process_Decisions;

   ---------------------
   -- Instrument_Unit --
   ---------------------

   procedure Instrument_Unit (Unit_Name : String) is
      Ctx  : Analysis_Context := Create;
      Unit : Analysis_Unit := Get_From_File (Ctx, Unit_Name);
   begin
      Traverse_Declarations_Or_Statements (Root (Unit));
      Destroy (Ctx);
   end Instrument_Unit;

   ------------------
   -- Has_Decision --
   ------------------

   function Has_Decision (T : Ada_Node'Class) return Boolean is
      function Visit (N : Ada_Node'Class) return Visit_Status;
      --  If N's kind indicates the presence of a decision, return Stop,
      --  otherwise return Into.
      --
      --  We know have a decision as soon as we have a logical operator (by
      --  definition) or an IF-expression (its condition is a decision).

      -----------
      -- Visit --
      -----------

      function Visit (N : Ada_Node'Class) return Visit_Status is
      begin
         if Is_Logical_Operator (N) /= False
           or else Nkind (N) = Ada_If_Expression
         then
            return Stop;
         else
            return Into;
         end if;
      end Visit;

   --  Start of processing for Has_Decision

   begin
      return T.Traverse (Visit'Access) = Stop;
   end Has_Decision;

   -------------------------
   -- Is_Logical_Operator --
   -------------------------

   function Is_Logical_Operator (N : Ada_Node'Class) return Tristate is
   begin
      case Operator (N.As_Expr).Kind is
         when Ada_Op_Not =>
            return True;
            --  Ada_Op_Not should be Unkwown???

         when Ada_Op_And_Then | Ada_Op_Or_Else =>
            return True;

         when Ada_Op_And | Ada_Op_Or =>
            return Unknown;

         when others =>
            return False;
      end case;
   end Is_Logical_Operator;

   --------------
   -- Operator --
   --------------

   function Operator (N : Expr) return Op is
   begin
      case N.Kind is
         when Ada_Un_Op =>
            return N.As_Un_Op.F_Op;
         when Ada_Bin_Op =>
            return N.As_Bin_Op.F_Op;
         when others =>
            return No_Op;
      end case;
   end Operator;

   -------------
   -- As_Name --
   -------------

   function As_Name (Id : Identifier) return Name_Id is
   begin
      --  Note: we really care only about Name_Ids for identifiers of pragmas
      --  and aspects, which we assume never contain wide-wide characters.

      return Name_Find (To_String (Canonicalize (Id.Text).Symbol));
   end As_Name;

   -------------
   -- As_Name --
   -------------

   function As_Symbol (Id : Identifier) return Symbol_Type is
     (Find (Symbols, Canonicalize (Id.Text).Symbol));

   -----------------
   -- Pragma_Name --
   -----------------

   function Pragma_Name (P : Pragma_Node) return Symbol_Type is
     (As_Symbol (P.F_Id));

   -----------------------
   -- Aspect_Assoc_Name --
   -----------------------

   function Aspect_Assoc_Name (A : Aspect_Assoc) return Symbol_Type is
      AM : constant Name := A.F_Id;
      --  aspect_mark of A

      AI : Identifier;
   begin
      --  Note: we just ignore a possible 'Class (we treat [Pre|Post]'Class
      --  just like Pre/Post).

      if AM.Kind = Ada_Attribute_Ref then
         AI := AM.As_Attribute_Ref.F_Prefix.As_Identifier;
      else
         AI := AM.As_Identifier;
      end if;

      return As_Symbol (AI);
   end Aspect_Assoc_Name;

end Instrument;