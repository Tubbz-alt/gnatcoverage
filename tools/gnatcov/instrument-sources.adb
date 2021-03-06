------------------------------------------------------------------------------
--                                                                          --
--                               GNATcoverage                               --
--                                                                          --
--                     Copyright (C) 2008-2020, AdaCore                     --
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

with Ada.Characters.Conversions; use Ada.Characters.Conversions;
with Ada.Containers;
with Ada.Exceptions;
with Ada.Strings;

with GNATCOLL.Projects; use GNATCOLL.Projects;

with SCOs;

with Coverage;        use Coverage;
with Diagnostics;     use Diagnostics;
with Files_Table;     use Files_Table;
with Instrument.Tree; use Instrument.Tree;
with Slocs;
with Strings;         use Strings;
with Text_Files;

package body Instrument.Sources is

   package LAL renames Libadalang.Analysis;

   function Expr_Needs_Parens (Kind : Ada_Node_Kind_Type) return Boolean
   is (Kind in Ada_Quantified_Expr | Ada_If_Expr | Ada_Case_Expr);
   --  Whether nodes of type Kind must be wrapped with parens

   function Create_Identifier
     (RH : Rewriting_Handle; Text : Text_Type) return Node_Rewriting_Handle
   is (Create_Token_Node (RH, Libadalang.Common.Ada_Identifier, Text));

   function To_Nodes
     (Handle : Rewriting_Handle;
      Name   : Ada_Qualified_Name) return Node_Rewriting_Handle
      with Pre => not Name.Is_Empty;
   --  Turn the given qualified name into a name tree for rewriting

   package Ada_Qualified_Name_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Ada_Qualified_Name,
      "="          => Ada_Identifier_Vectors."=");

   function Buffer_Units_For_Closure
     (IC   : Inst_Context;
      Main : Ada_Qualified_Name)
      return Ada_Qualified_Name_Vectors.Vector;
   --  Return the list of buffer units names for all units of interest in
   --  Main's closure. If for some reason we cannot get this list, just return
   --  an empty one.

   procedure Emit_Dump_Helper_Unit
     (IC          : Inst_Context;
      Info        : in out Project_Info;
      Main        : Ada_Qualified_Name;
      Helper_Unit : out Ada_Qualified_Name);
   --  Emit the unit to contain helpers to implement the automatic dump of
   --  coverage buffers for the given Main unit. Info must be the project that
   --  owns this main. Upon return, the name of this helper unit is stored in
   --  Helper_Unit.

   function Expression_Type
     (UIC : Unit_Inst_Context;
      E   : Expr) return Base_Type_Decl;
   --  Wrapper around E.P_Expression_Type, logging a warning and returning
   --  Standard.Boolean if unable to determine the type.

   function Referenced_Defining_Name
     (Main_Name : Ada_Qualified_Name;
      N         : LAL.Name) return Defining_Name;
   --  Wrapper around Name.P_Referenced_Defining_Name, logging a warning and
   --  returning No_Defining_Name if unable to determine the referenced
   --  defining name.

   -------------------------------------
   -- Generation of witness fragments --
   -------------------------------------

   function Convert_To
     (IC                 : in out Unit_Inst_Context;
      From_Type, To_Type : Base_Type_Decl;
      RH_N               : Node_Rewriting_Handle)
      return Node_Rewriting_Handle;
   --  Given an expression RH_N of type From_Type, return an expression of type
   --  To_Type, introducing a type conversion if needed. Both types are
   --  expected to be boolean types (i.e. Standard.Boolean or any of its
   --  descendants).

   function Make_Decision_Witness
     (IC         : in out Unit_Inst_Context;
      Bits       : Decision_Bit_Ids;
      MCDC_State : Unbounded_String;
      Decision   : Node_Rewriting_Handle) return Node_Rewriting_Handle;
   --  Create a function call to witness the outcome of the given decision,
   --  to be recorded using the given bit ids. If MC/DC is requested,
   --  MCDC_State is the name of the MC/DC state local variable, else it
   --  is the empty string.

   function Make_Condition_Witness
     (IC         : in out Unit_Inst_Context;
      MCDC_State : Unbounded_String;
      Condition  : Node_Rewriting_Handle;
      Offset     : Natural;
      First      : Boolean) return Node_Rewriting_Handle;
   --  Create a function call to witness the value of the given condition,
   --  to be recorded in the given MC/DC state local variable.

   procedure Insert_Condition_Witness
     (IC     : in out Unit_Inst_Context;
      SC     : Source_Condition;
      Offset : Natural);
   --  For use when MC/DC is requested. Insert witness function call for the
   --  identified condition.

   procedure Insert_Decision_Witness
     (IC         : in out Unit_Inst_Context;
      SD         : Source_Decision;
      Path_Count : Positive);
   --  For use when decision coverage or MC/DC is requested. Insert witness
   --  function call for the identified condition.

   ----------------
   -- Convert_To --
   ----------------

   function Convert_To
     (IC                 : in out Unit_Inst_Context;
      From_Type, To_Type : Base_Type_Decl;
      RH_N               : Node_Rewriting_Handle)
      return Node_Rewriting_Handle
   is
   begin
      --  Guard against failure to type some expression, and return node
      --  unchanged if no conversion is required.

      if From_Type.Is_Null
           or else
         To_Type.Is_Null
           or else
         From_Type = To_Type
      then
         return RH_N;
      else
         if To_Type /= To_Type.P_Bool_Type.As_Base_Type_Decl then
            Ensure_With
              (IC,
               To_Type
               .P_Top_Level_Decl (To_Type.Unit)
               .P_Canonical_Fully_Qualified_Name);
         end if;

         return Create_Call_Expr
           (IC.Rewriting_Context,
            Call_Expr_F_Name   =>
              Create_Identifier
                (IC.Rewriting_Context,
                 To_Type.P_Canonical_Fully_Qualified_Name),
            Call_Expr_F_Suffix => RH_N);
      end if;
   end Convert_To;

   ---------------------------
   -- Make_Decision_Witness --
   ---------------------------

   function Make_Decision_Witness
     (IC         : in out Unit_Inst_Context;
      Bits       : Decision_Bit_Ids;
      MCDC_State : Unbounded_String;
      Decision   : Node_Rewriting_Handle) return Node_Rewriting_Handle
   is
      E : Instrumentation_Entities renames IC.Entities;
      D : Node_Rewriting_Handle := Decision;

      Is_MCDC : constant Boolean := Bits.Path_Bits_Base /= No_Bit_Id;

      --  Note: we can't pass Decision directly as a subsitution to
      --  Create_From_Template, as this would unparse it and create a
      --  complete new tree, whereas we want to preserve the original
      --  tree so that we can instrument individual conditions for MC/DC.

      Call_Img : constant String :=
        "{}.Witness ({}"
        & "," & Img (Bits.Outcome_Bits (False))
        & "," & Img (Bits.Outcome_Bits (True))
        & (if Is_MCDC
           then ", {}"
                & ", " & Img (Bits.Path_Bits_Base)
                & ", " & To_String (MCDC_State)
           else "")
        & ")";

      RH_Call : constant Node_Rewriting_Handle :=
        Create_From_Template
          (IC.Rewriting_Context,
           Template  => To_Wide_Wide_String (Call_Img),
           Arguments => (1 => E.Common_Buffers,
                         2 => E.Decision_Buffer)
                        & (if Is_MCDC
                           then (1 => E.MCDC_Buffer)
                           else (1 .. 0 => No_Node_Rewriting_Handle)),
           Rule      => Expr_Rule);

      D_Node : constant Expr := Node (Decision).As_Expr;
      D_Type : constant Base_Type_Decl := Expression_Type (IC, D_Node);
      B_Type : constant Base_Type_Decl := D_Node.P_Bool_Type.As_Base_Type_Decl;

   begin
      --  Wrap decisions with parens if their syntax requires. We can't always
      --  move the parens that wrap the decision in sources because they can
      --  sometimes belong to another syntactic construct, for instance:
      --
      --     pragma Assert (if A then B);

      if Expr_Needs_Parens (Kind (D)) then
         D := Create_Paren_Expr (IC.Rewriting_Context, D);
      end if;
      D := Convert_To (IC, D_Type, B_Type, D);

      --  The second child of RH_Call is its list of actual parameters

      Append_Child (Child (RH_Call, 2), D);
      return Convert_To (IC, B_Type, D_Type, RH_Call);
   end Make_Decision_Witness;

   ----------------------------
   -- Make_Condition_Witness --
   ----------------------------

   function Make_Condition_Witness
     (IC         : in out Unit_Inst_Context;
      MCDC_State : Unbounded_String;
      Condition  : Node_Rewriting_Handle;
      Offset     : Natural;
      First      : Boolean) return Node_Rewriting_Handle
   is
      E        : Instrumentation_Entities renames IC.Entities;
      Call_Img : constant String :=
        "{}.Witness (" & To_String (MCDC_State) & ","
        & Img (Offset) & "," & First'Img & ")";

      RH_Call : constant Node_Rewriting_Handle :=
        Create_From_Template
          (IC.Rewriting_Context,
           Template  => To_Wide_Wide_String (Call_Img),
           Arguments => (1 => E.Common_Buffers),
           Rule      => Expr_Rule);

      C_Node : constant Expr := Node (Condition).As_Expr;
      C_Type : constant Base_Type_Decl := Expression_Type (IC, C_Node);
      B_Type : constant Base_Type_Decl := C_Node.P_Bool_Type.As_Base_Type_Decl;

   begin
      --  The second child of RH_Call is its list of actual parameters

      Append_Child
        (Child (RH_Call, 2), Convert_To (IC, C_Type, B_Type, Condition));
      return Convert_To (IC, B_Type, C_Type, RH_Call);
   end Make_Condition_Witness;

   --------------
   -- To_Nodes --
   --------------

   function To_Nodes
     (Handle : Rewriting_Handle;
      Name   : Ada_Qualified_Name) return Node_Rewriting_Handle
   is
      Result : Node_Rewriting_Handle := No_Node_Rewriting_Handle;
   begin
      for Id of Name loop
         declare
            Id_Node : constant Node_Rewriting_Handle := Create_Identifier
              (Handle, To_Text (To_String (Id)));
         begin
            if Result = No_Node_Rewriting_Handle then
               Result := Id_Node;
            else
               Result := Create_Dotted_Name (Handle, Result, Id_Node);
            end if;
         end;
      end loop;
      return Result;
   end To_Nodes;

   --------------------------
   -- Initialize_Rewriting --
   --------------------------

   procedure Initialize_Rewriting
     (IC                : out Unit_Inst_Context;
      Instrumented_Unit : Compilation_Unit_Name;
      Context           : Analysis_Context) is
   begin
      IC.Instrumented_Unit := Instrumented_Unit;
      IC.Buffer_Unit := (Buffer_Unit (Instrumented_Unit), Unit_Spec);
      IC.Pure_Buffer_Unit := (Pure_Buffer_Unit (Instrumented_Unit), Unit_Spec);
      IC.Rewriting_Context := Handle (Context);

      declare
         RH : constant Rewriting_Handle := IC.Rewriting_Context;
         E  : Instrumentation_Entities renames IC.Entities;
      begin
         E.Common_Buffers := To_Nodes (RH, Sys_Buffers);
         E.Unit_Buffers := To_Nodes (RH, IC.Pure_Buffer_Unit.Unit);
         E.Statement_Buffer :=
            To_Nodes (RH, IC.Pure_Buffer_Unit.Unit & Statement_Buffer_Name);

         if Coverage.Enabled (Decision) or else MCDC_Coverage_Enabled then
            E.Decision_Buffer :=
              To_Nodes (RH, IC.Pure_Buffer_Unit.Unit & Decision_Buffer_Name);

            if MCDC_Coverage_Enabled then
               E.MCDC_Buffer :=
                 To_Nodes (RH, IC.Pure_Buffer_Unit.Unit & MCDC_Buffer_Name);
            end if;
         end if;
      end;
   end Initialize_Rewriting;

   ------------------------------
   -- Buffer_Units_For_Closure --
   ------------------------------

   function Buffer_Units_For_Closure
     (IC   : Inst_Context;
      Main : Ada_Qualified_Name)
      return Ada_Qualified_Name_Vectors.Vector
   is
      pragma Unreferenced (Main);
      Result : Ada_Qualified_Name_Vectors.Vector;
   begin
      --  TODO??? Here, we need the list of files needed to build Main: specs
      --  for units WITHed by main, their bodies, the separates, etc.  It's
      --  unclear what GNATCOLL.Projects.Get_Closure does, but experimentations
      --  show that it's not what we want. So for now, return an approximation:
      --  buffer units for all instrumented units. In the future, we should
      --  either get this service from GNATCOLL.Projects, either re-implement
      --  it on top of Libadalang.

      for Cur in IC.Instrumented_Units.Iterate loop
         declare
            Instr_Unit : constant Compilation_Unit_Name :=
               Instrumented_Unit_Maps.Key (Cur);
         begin
            Result.Append (Buffer_Unit (Instr_Unit));
         end;
      end loop;
      return Result;
   end Buffer_Units_For_Closure;

   ---------------------------
   -- Emit_Dump_Helper_Unit --
   ---------------------------

   procedure Emit_Dump_Helper_Unit
     (IC          : Inst_Context;
      Info        : in out Project_Info;
      Main        : Ada_Qualified_Name;
      Helper_Unit : out Ada_Qualified_Name)
   is
      File : Text_Files.File_Type;

      procedure Put_With (Unit : Ada_Qualified_Name);
      --  Put a "with" context clause in File

      --------------
      -- Put_With --
      --------------

      procedure Put_With (Unit : Ada_Qualified_Name) is
      begin
         File.Put_Line ("with " & To_Ada (Unit) & ";");
      end Put_With;

      Output_Unit, Output_Proc : Ada_Qualified_Name;
      --  Qualified names for the unit that contains the buffer output
      --  procedure, and for the procedure itself.

      Dump_Trigger : constant Auto_Dump_Trigger := IC.Dump_Trigger;
      --  Shortcut to avoid repeatedly restricting the dump trigger to the
      --  Auto_Dump_Trigger subtype.

   --  Start of processing for Emit_Dump_Helper_Unit

   begin
      --  Create the name of the helper unit

      Helper_Unit := Sys_Buffers;
      Helper_Unit.Append
        (To_Unbounded_String ("D")
         & Instrumented_Unit_Slug ((Main, Unit_Body)));

      --  Compute the qualified names we need for instrumentation

      declare
         use type Ada_Qualified_Name;
         Unit : constant String := (case IC.Dump_Channel is
                                    when Binary_File            => "Files",
                                    when Base64_Standard_Output => "Base64");
      begin
         Output_Unit := Sys_Prefix
                        & To_Unbounded_String ("Traces")
                        & To_Unbounded_String ("Output")
                        & To_Unbounded_String (Unit);
         Output_Proc := Output_Unit & To_Unbounded_String ("Write_Trace_File");
      end;

      declare
         Helper_Unit_Name : constant String := To_Ada (Helper_Unit);
         Dump_Procedure   : constant String := To_String (Dump_Procedure_Name);

         Buffer_Units : constant Ada_Qualified_Name_Vectors.Vector :=
            Buffer_Units_For_Closure (IC, Main);
         --  List of names for units that contains the buffers to dump

      begin
         --  Emit the package spec. This includes one Dump_Buffers procedure,
         --  which dumps all coverage buffers in Main's closure to the source
         --  trace file.

         Create_File
           (Info, File, To_Filename (Info.Project, (Helper_Unit, Unit_Spec)));
         Put_Warnings_And_Style_Checks_Pragmas (File);
         File.Put_Line ("package " & Helper_Unit_Name & " is");
         File.New_Line;
         File.Put_Line ("   procedure " & Dump_Procedure & ";");
         File.Put_Line ("   pragma Export (C, " & Dump_Procedure & ");");
         File.New_Line;

         case Dump_Trigger is
            when At_Exit | Ravenscar_Task_Termination =>
               File.Put_Line
                 ("procedure "
                  & To_String (Register_Dump_Procedure_Name) & ";");
               File.New_Line;

            when Main_End =>
               null;
         end case;

         File.Put_Line ("end " & Helper_Unit_Name & ";");
         File.Close;

         --  Emit the package body

         Create_File
           (Info, File, To_Filename (Info.Project, (Helper_Unit, Unit_Body)));
         Put_Warnings_And_Style_Checks_Pragmas (File);

         Put_With (Output_Unit);
         for Buffer_Unit of Buffer_Units loop
            Put_With (Buffer_Unit);
         end loop;

         case Dump_Trigger is
            when At_Exit  =>
               File.Put_Line ("with Interfaces.C;");
            when Ravenscar_Task_Termination  =>
               File.Put_Line ("with Ada.Task_Identification;");
               File.Put_Line ("with Ada.Task_Termination;");
            when Main_End =>
               null;
         end case;

         File.Put_Line ("package body " & Helper_Unit_Name & " is");
         File.New_Line;

         --  Emit the procedure to write the trace file

         File.Put_Line ("   procedure " & Dump_Procedure & " is");
         File.Put_Line ("   begin");
         File.Put_Line ("      " & To_Ada (Output_Proc));
         File.Put      ("        ((");
         for Cur in Buffer_Units.Iterate loop
            declare
               use Ada_Qualified_Name_Vectors;

               Index       : constant Positive := To_Index (Cur);
               Buffer_Name : constant String :=
                  To_Ada (Element (Cur)) & ".Buffers";

            begin
               File.Put (Strings.Img (To_Index (Cur))
                         & " => " & Buffer_Name & "'Access");
               if Index = Buffer_Units.Last_Index then
                  File.Put_Line ("),");
               else
                  File.Put_Line (",");
                  File.Put ((1 .. 10 => ' '));
               end if;
            end;
         end loop;

         case IC.Dump_Channel is
         when Binary_File =>
            File.Put ("         Filename => "
                      & To_Ada (Output_Unit) & ".Default_Trace_Filename");

         when Base64_Standard_Output =>

            --  Configurations using this channel generally run on embedded
            --  targets and have a small runtime, so our best guess for the
            --  program name is the name of the main, and there is no way to
            --  get the current execution time.

            File.Put_Line
              ("         Program_Name => """ & To_Ada (Main) & """,");
            File.Put ("         Exec_Date => (others => ASCII.NUL)");
         end case;
         File.Put_Line (");");

         File.Put_Line ("   end " & Dump_Procedure & ";");
         File.New_Line;

         --  Emit trigger-specific procedures

         case Dump_Trigger is
            when At_Exit =>

               --  Emit a procedure to schedule a trace dump with atexit

               File.Put_Line
                 ("procedure "
                  & To_String (Register_Dump_Procedure_Name) & " is");
               File.Put_Line ("   type Callback is access procedure;");
               File.Put_Line ("   pragma Convention (C, Callback);");
               File.New_Line;
               File.Put_Line ("   function atexit (Func : Callback)"
                              & " return Interfaces.C.int;");
               File.Put_Line ("   pragma Import (C, atexit);");
               File.Put_Line ("   Dummy : constant Interfaces.C.int :=");
               File.Put_Line ("     atexit (" & Dump_Procedure & "'Access);");
               File.Put_Line ("begin");
               File.Put_Line ("   null;");
               File.Put_Line
                 ("end " & To_String (Register_Dump_Procedure_Name) & ";");
               File.New_Line;

            when Ravenscar_Task_Termination =>

               --  Emit a protected object for the callback

               File.Put_Line ("  protected Wrapper is");
               File.Put_Line ("     procedure Do_Dump"
                              & " (T : Ada.Task_Identification.Task_Id);");
               File.Put_Line ("  end Wrapper;");
               File.New_Line;
               File.Put_Line ("  protected body Wrapper is");
               File.Put_Line ("     procedure Do_Dump"
                              & " (T : Ada.Task_Identification.Task_Id) is");
               File.Put_Line ("        pragma Unreferenced (T);");
               File.Put_Line ("     begin");
               File.Put_Line ("        " & Dump_Procedure & ";");
               File.Put_Line ("     end Do_Dump;");
               File.Put_Line ("  end Wrapper;");
               File.New_Line;

               --  Emit a procedure to schedule a trace dump with
               --  Ada.Task_Termination.

               File.Put_Line
                 ("procedure "
                  & To_String (Register_Dump_Procedure_Name) & " is");
               File.Put_Line ("begin");
               File.Put_Line ("   Ada.Task_Termination"
                              & ".Set_Dependents_Fallback_Handler"
                              & " (Wrapper.Do_Dump'Access);");
               File.Put_Line
                 ("end " & To_String (Register_Dump_Procedure_Name) & ";");
               File.New_Line;

            when Main_End =>
               null;
         end case;

         File.Put_Line ("end " & Helper_Unit_Name & ";");
         File.Close;
      end;
   end Emit_Dump_Helper_Unit;

   ---------------------
   -- Expression_Type --
   ---------------------

   function Expression_Type
     (UIC : Unit_Inst_Context;
      E   : Expr) return Base_Type_Decl
   is
      ET : Base_Type_Decl;
   begin
      begin
         ET := E.P_Expression_Type;

         if ET.Is_Null then
            Report
              (UIC, E,
               "failed to determine expression type (got null type)",
               Warning);
         end if;

      exception
         when Exc : Property_Error =>
            Report
              (UIC, E,
               "failed to determine expression type: "
                 & Ada.Exceptions.Exception_Information (Exc),
               Warning);
      end;

      if not ET.Is_Null then
         return ET;
      else
         return E.P_Bool_Type.As_Base_Type_Decl;
      end if;
   end Expression_Type;

   ------------------------------
   -- Referenced_Defining_Name --
   ------------------------------

   function Referenced_Defining_Name
     (Main_Name : Ada_Qualified_Name;
      N         : LAL.Name) return Defining_Name
   is
      DF : Defining_Name;
   begin
      begin
         DF := N.P_Referenced_Defining_Name;

         if DF.Is_Null then
            Report
              (Kind => Warning,
               Msg  => "Failed to determine referenced defining name while "
               & "processing the main " & To_Ada (Main_Name) & " (got null "
               & "defining name)");
         end if;

      exception
         when Exc : Property_Error =>
            Report
              (Kind => Warning,
               Msg  => "Failed to determine referenced defining name while "
               & "processing the main " & To_Ada (Main_Name) & ": "
               & Ada.Exceptions.Exception_Information (Exc));
      end;
      if not DF.Is_Null then
         return DF;
      else
         return No_Defining_Name;
      end if;
   end Referenced_Defining_Name;

   -----------------------------
   -- Index_In_Rewriting_Tree --
   -----------------------------

   function Index_In_Rewriting_Tree (N : Ada_Node'Class) return Positive is
      RH : constant Node_Rewriting_Handle := Handle (N);
      P  : constant Node_Rewriting_Handle := Parent (RH);
   begin
      pragma Assert (P /= No_Node_Rewriting_Handle);
      for I in 1 .. Children_Count (P) loop
         if Child (P, I) = RH then
            return I;
         end if;
      end loop;

      --  If we reach this point, this means the rewriting tree is corrupted (a
      --  node does not belong to its parent's children).

      return (raise Program_Error with "corrupted rewriting tree");
   end Index_In_Rewriting_Tree;

   ------------
   -- Detach --
   ------------

   function Detach (N : Ada_Node'Class) return Node_Rewriting_Handle is
   begin
      if N.Is_Null then
         return No_Node_Rewriting_Handle;
      end if;

      return H : constant Node_Rewriting_Handle := Handle (N) do
         Replace (H, No_Node_Rewriting_Handle);
      end return;
   end Detach;

   ---------------------------
   -- Add_Auto_Dump_Buffers --
   ---------------------------

   procedure Add_Auto_Dump_Buffers
     (IC   : Inst_Context;
      Info : in out Project_Info;
      Main : Ada_Qualified_Name;
      URH  : Unit_Rewriting_Handle)
   is
      No_Node : Node_Rewriting_Handle renames No_Node_Rewriting_Handle;

      U   : constant Analysis_Unit := Unit (URH);
      RH  : constant Rewriting_Handle := Handle (U.Context);
      Tmp : LAL.Ada_Node := U.Root;

      CU        : LAL.Compilation_Unit;
      Subp_Body : LAL.Subp_Body;

      Old_Stmts, New_Stmts : Node_Rewriting_Handle;

      New_Stmt_List        : constant Node_Rewriting_Handle :=
         Create_Node (RH, Ada_Stmt_List);
      --  List of statements to contain 1) the original handled statements
      --  (Old_Stmts) and 2) the call to the Write_Trace_File procedure.

      Buffer_Units : constant Ada_Qualified_Name_Vectors.Vector :=
         Buffer_Units_For_Closure (IC, Main);
      --  List of names for units that contains the buffers to dump

      Helper_Unit : Ada_Qualified_Name;
      --  Name of unit to contain helpers implementing the buffers dump

   begin
      if Buffer_Units.Is_Empty then
         return;
      end if;

      --  Make sure this main source has the expected structure: a
      --  simple subprogram body in a compilation unit. If not, return without
      --  doing anything.

      if Tmp.Kind /= Ada_Compilation_Unit then
         return;
      else
         CU := Tmp.As_Compilation_Unit;
      end if;

      Tmp := CU.F_Body;
      if Tmp.Kind /= Ada_Library_Item then
         return;
      end if;

      Tmp := Tmp.As_Library_Item.F_Item.As_Ada_Node;
      if Tmp.Kind /= Ada_Subp_Body then
         return;
      else
         Subp_Body := Tmp.As_Subp_Body;
      end if;

      --  Emit the helper unit and add a WITH clause for it

      Emit_Dump_Helper_Unit (IC, Info, Main, Helper_Unit);

      declare
         Prelude : constant Node_Rewriting_Handle := Handle (CU.F_Prelude);

         With_Clause : constant Node_Rewriting_Handle :=
            Create_From_Template
              (RH,
               Template  => "with {};",
               Arguments => (1 => To_Nodes (RH, Helper_Unit)),
               Rule      => With_Clause_Rule);

      begin
         Append_Child (Prelude, With_Clause);
      end;

      --  Wrap the previous subprogram body content (declarations, handled
      --  statements) in a declare block. This is a simple handled statements
      --  block if there is no declaration.

      declare
         New_Excs : constant Node_Rewriting_Handle :=
            Create_Node (RH, Ada_Ada_Node_List);

         Nested_Block : Node_Rewriting_Handle;
         Nested_Decls : Node_Rewriting_Handle;

         Main_Name  : constant LAL.Defining_Name :=
           Subp_Body.F_Subp_Spec.F_Subp_Name;
         Block_Name : constant Node_Rewriting_Handle :=
           Create_Identifier (RH, "GNATcov_Original_Main");

         function Replace_FQNs
           (Node : LAL.Ada_Node'Class) return Visit_Status;
         --  Callback for Libadalang's Traverse. If Node is a dotted name whose
         --  prefix refers to Main, rewrite the prefix to refer to the named
         --  block we create here.

         -----------------
         -- Replace_FQN --
         -----------------

         function Replace_FQNs
           (Node : LAL.Ada_Node'Class) return Visit_Status
         is
            Name : Dotted_Name;
         begin
            if Node.Kind /= Ada_Dotted_Name then
               return Into;
            end if;
            Name := Node.As_Dotted_Name;
            if Referenced_Defining_Name (Main, Name.F_Prefix) = Main_Name then
               declare
                  Old_Prefix : constant Node_Rewriting_Handle :=
                    Handle (Name.F_Prefix);
                  New_Node   : constant Node_Rewriting_Handle :=
                    Create_Regular_Node
                      (RH,
                       Ada_Dotted_Name,
                       (No_Node_Rewriting_Handle,
                        Clone (Block_Name)));
               begin
                  Replace (Old_Prefix, New_Node);
                  Set_Child (Handle => New_Node,
                             Index  => 1,
                             Child  => Old_Prefix);
                  return Over;
               end;
            end if;
            return Into;
         end Replace_FQNs;

      begin
         --  Extract the original statements (Old_Stmts) and replace it in the
         --  subprogram body with the new statements.

         Old_Stmts := Handle (Subp_Body.F_Stmts);
         New_Stmts := Create_Regular_Node
           (RH, Ada_Handled_Stmts, (New_Stmt_List, New_Excs));
         Replace (Old_Stmts, New_Stmts);

         --  If the original subprogram has declarations or exception handlers,
         --  wrap the original statements in a named block to hold them.

         if Subp_Body.F_Decls.F_Decls.Children_Count = 0
           and then Subp_Body.F_Stmts.F_Exceptions.Children_Count = 0
         then
            Nested_Block := Old_Stmts;
         else
            Nested_Decls := Handle (Subp_Body.F_Decls);
            Replace
              (Nested_Decls,
               Create_Regular_Node
                 (RH, Ada_Declarative_Part,
                  (1 => Create_Node (RH, Ada_Ada_Node_List))));

            Nested_Block := Create_Named_Stmt
              (RH,
               Named_Stmt_F_Decl => Create_Named_Stmt_Decl
                 (RH,
                  Create_Defining_Name
                    (RH, Clone (Block_Name)),
                  No_Node),
               Named_Stmt_F_Stmt => Create_Regular_Node
                 (RH, Ada_Decl_Block,
                  (Nested_Decls,
                   Old_Stmts,
                   Clone (Block_Name))));

            --  Change the Qualified names in the Main's declarations and
            --  statements to be compatible ith the new nested block.
            Subp_Body.F_Stmts.Traverse (Replace_FQNs'Access);
            Subp_Body.F_Decls.Traverse (Replace_FQNs'Access);

         end if;
         Append_Child (New_Stmt_List, Nested_Block);
      end;

      --  Depending on the chosen coverage buffers dump trigger, insert the
      --  appropriate code.

      case Auto_Dump_Trigger (IC.Dump_Trigger) is

      when At_Exit | Ravenscar_Task_Termination =>

         --  Build the call to the registration procedure and insert it in
         --  New_Stmt_List, right before the old list of statements.

         declare
            Register_Procedure : Ada_Qualified_Name;
            --  Name of the procedure to register the coverage buffers dump
            --  routine.

            Call_Stmt : Node_Rewriting_Handle;

         begin
            Register_Procedure := Helper_Unit;
            Register_Procedure.Append (Register_Dump_Procedure_Name);

            Call_Stmt := Create_Regular_Node
              (RH, Ada_Call_Stmt, (1 => To_Nodes (RH, Register_Procedure)));
            Insert_Child (New_Stmt_List, 1, Call_Stmt);
         end;

      when Main_End =>

         --  Build the call to the dump procedure and append it to
         --  New_Stmt_List, right after the old list of statements.

         declare
            Dump_Procedure : Ada_Qualified_Name;
            --  Name of the procedure to dump coverage buffers

            Call_Stmt : Node_Rewriting_Handle;

         begin
            Dump_Procedure := Helper_Unit;
            Dump_Procedure.Append (Dump_Procedure_Name);

            Call_Stmt := Create_Regular_Node
              (RH, Ada_Call_Stmt, (1 => To_Nodes (RH, Dump_Procedure)));
            Append_Child (New_Stmt_List, Call_Stmt);
         end;

      end case;
   end Add_Auto_Dump_Buffers;

   ------------------------------
   -- Insert_Condition_Witness --
   ------------------------------

   procedure Insert_Condition_Witness
     (IC     : in out Unit_Inst_Context;
      SC     : Source_Condition;
      Offset : Natural)
   is
      N : Expr renames SC.Condition;

      RH_P : constant Node_Rewriting_Handle :=
        Create_Node
          (IC.Rewriting_Context, Libadalang.Common.Ada_Identifier);
      RH_N : Node_Rewriting_Handle;

   begin
      --  No instrumentation for condition if there is no local state variable

      if Length (SC.State) = 0 then
         return;
      end if;

      --  Special case of conditional and quantified expressions: we need to
      --  move them along with their enclosing parentheses.

      if Expr_Needs_Parens (N.Kind) then
         pragma Assert (Kind (N.Parent) = Ada_Paren_Expr);
         RH_N := Handle (N.Parent);
      else
         RH_N := Handle (N);
      end if;

      --  Detach original condition from tree so that it can be reattached
      --  inside the witness call.

      Replace (RH_N, RH_P);

      --  Now attach witness call at the place of the original condition

      Replace
        (RH_P,
         Make_Condition_Witness (IC, SC.State, RH_N, Offset, SC.First));
   end Insert_Condition_Witness;

   -----------------------------
   -- Insert_Decision_Witness --
   -----------------------------

   procedure Insert_Decision_Witness
     (IC         : in out Unit_Inst_Context;
      SD         : Source_Decision;
      Path_Count : Positive)
   is
      LL_SCO_Id : Nat renames SD.LL_SCO;
      N         : Expr renames SD.Decision;

      Bits : Decision_Bit_Ids;
      RH_P : constant Node_Rewriting_Handle :=
        Create_Node
          (IC.Rewriting_Context, Libadalang.Common.Ada_Identifier);

      RH_N : constant Node_Rewriting_Handle := Handle (N);
   begin
      Bits.LL_D_SCO := LL_SCO_Id;

      --  Allocate outcome bits

      Bits.Outcome_Bits :=
        (False => IC.Unit_Bits.Last_Outcome_Bit + 1,
         True  => IC.Unit_Bits.Last_Outcome_Bit + 2);
      IC.Unit_Bits.Last_Outcome_Bit :=
        IC.Unit_Bits.Last_Outcome_Bit + 2;

      --  Allocate path bits for MC/DC if MC/DC is required and we were
      --  able to generate a local state variable.

      if MCDC_Coverage_Enabled and then Length (SD.State) > 0 then
         Bits.Path_Bits_Base := IC.Unit_Bits.Last_Path_Bit + 1;
         IC.Unit_Bits.Last_Path_Bit :=
           IC.Unit_Bits.Last_Path_Bit + Bit_Id (Path_Count);
      else
         Bits.Path_Bits_Base := No_Bit_Id;
      end if;

      IC.Unit_Bits.Decision_Bits.Append (Bits);

      --  Detach original decision from tree so that it can be reattached
      --  inside the witness call.

      Replace (RH_N, RH_P);

      --  Now attach witness call at the place of the original decision

      Replace (RH_P,
        Make_Decision_Witness (IC, Bits, SD.State, RH_N));
   end Insert_Decision_Witness;

   ----------------------------
   -- Instrument_Source_File --
   ----------------------------

   procedure Instrument_Source_File
     (CU_Name   : Compilation_Unit_Name;
      Unit_Info : Instrumented_Unit_Info;
      Prj_Info  : in out Project_Info;
      IC        : in out Inst_Context;
      UIC       : out Unit_Inst_Context)
   is
      Rewriter : Source_Rewriter;
      Filename : constant String := To_String (Unit_Info.Filename);

      Root_Analysis_Unit : Analysis_Unit;

      Preelab : Boolean;
      --  Set to True if Unit is required to be preelaborable, i.e.  it is
      --  either preelaborated, or the declaration of a remote types or
      --  remote call interface library unit. In this case, do not generate
      --  any witness calls for elaboration of declarations: they would be
      --  pointless (there is no elaboration code anyway) and, in any case,
      --  illegal.

   begin
      Rewriter.Start_Rewriting (IC, Prj_Info, Filename);

      Root_Analysis_Unit := Rewriter.Rewritten_Unit;

      --  Determine whether Unit is required to be preelaborable, and whether
      --  we can insert witness calls (which are not preelaborable).

      UIC.Root_Unit := Root_Analysis_Unit.Root.As_Compilation_Unit;

      begin
         Preelab := UIC.Root_Unit.P_Is_Preelaborable
           and then UIC.Root_Unit.F_Body.Kind = Ada_Library_Item
           and then UIC.Root_Unit.F_Body.As_Library_Item.F_Item.Kind in
             Ada_Package_Decl
           | Ada_Package_Body
           | Ada_Generic_Package_Decl;
      exception
         when Libadalang.Common.Property_Error =>
            Report
              (Msg  => "failed to determine preelaboration constraint for "
                         & Filename,
               Kind => Warning);
            Preelab := False;
      end;

      Initialize_Rewriting (UIC, CU_Name, IC.Context);

      --  Make sure that the simple name of the instrumented source file is
      --  registered in our tables. This is required to properly detect when we
      --  try to load SCOs for the same unit from an ALI file, as ALI files
      --  only provide simple names.

      UIC.SFI := Get_Index_From_Generic_Name
        (Filename,
         Kind                => Files_Table.Source_File,
         Indexed_Simple_Name => True);

      --  Then run SCOs generation. This inserts calls to witness
      --  procedures/functions in the same pass.

      SCOs.Initialize;
      Traverse_Declarations_Or_Statements
        (IC      => IC,
         UIC     => UIC,
         L       => No_Ada_List,
         Preelab => Preelab,
         P       => Rewriter.Rewritten_Unit.Root);

      SCOs.SCO_Unit_Table.Append
        ((File_Name  => new String'(Filename),
          File_Index => UIC.SFI,
          Dep_Num    => 1,
          From       => SCOs.SCO_Table.First,
          To         => SCOs.SCO_Table.Last));

      --  Convert low level SCOs from the instrumenter to high level SCOs.
      --  This creates BDDs for every decision.

      declare
         SCO_Map       : aliased LL_HL_SCO_Map :=
           (SCOs.SCO_Table.First .. SCOs.SCO_Table.Last => No_SCO_Id);
         Bit_Maps      : CU_Bit_Maps;
         Created_Units : Created_Unit_Maps.Map;
      begin
         Process_Low_Level_SCOs
           (Provider      => Instrumenter,
            Origin        => UIC.SFI,
            Created_Units => Created_Units,
            SCO_Map       => SCO_Map'Access);

         --  In the instrumentation case, the origin of SCO information is
         --  the original source file.

         UIC.CU := Created_Units.Element (UIC.SFI);

         --  Import annotations in our internal tables

         for Couple of UIC.Annotations loop
            declare
               Sloc : constant Slocs.Source_Location :=
                 (Source_File => UIC.SFI,
                  L           => (Line   => Positive (Couple.Sloc.Line),
                                  Column => Positive (Couple.Sloc.Column)));
            begin
               Couple.Annotation.CU := UIC.CU;
               ALI_Annotations.Insert
                 (Key => Sloc, New_Item => Couple.Annotation);
            end;
         end loop;

         --  Insert calls to condition/decision witnesses

         if Coverage.Enabled (Coverage.Decision) or else MCDC_Coverage_Enabled
         then
            for SD of UIC.Source_Decisions loop
               Insert_Decision_Witness
                 (UIC, SD, Path_Count (SCO_Map (SD.LL_SCO)));
            end loop;

            if MCDC_Coverage_Enabled then
               --  As high-level SCO tables have been populated, we have built
               --  BDDs for each decisions, and we can now set the correct
               --  MC/DC path offset for each condition.

               for SC of UIC.Source_Conditions loop
                  Insert_Condition_Witness
                    (UIC, SC, Offset_For_True (SCO_Map (SC.LL_SCO)));
               end loop;
            end if;
         end if;

         --  Witnesses have now been inserted, and bit indices allocated: build
         --  bit maps.

         Bit_Maps :=
           (Statement_Bits => new Statement_Bit_Map'
              (Bit_Id'First .. UIC.Unit_Bits.Last_Statement_Bit => No_SCO_Id),
            Decision_Bits  => new Decision_Bit_Map'
              (Bit_Id'First .. UIC.Unit_Bits.Last_Outcome_Bit =>
                   (No_SCO_Id, False)),
            MCDC_Bits      =>
               new MCDC_Bit_Map'(Bit_Id'First .. UIC.Unit_Bits.Last_Path_Bit =>
                                     (No_SCO_Id, 0)));

         for S_Bit_Alloc of UIC.Unit_Bits.Statement_Bits loop
            Bit_Maps.Statement_Bits (S_Bit_Alloc.Executed) :=
              SCO_Map (S_Bit_Alloc.LL_S_SCO);
         end loop;

         for D_Bit_Alloc of UIC.Unit_Bits.Decision_Bits loop
            declare
               D_SCO : constant SCO_Id := SCO_Map (D_Bit_Alloc.LL_D_SCO);
            begin
               for Outcome in Boolean loop
                  Bit_Maps.Decision_Bits
                    (D_Bit_Alloc.Outcome_Bits (Outcome)) :=
                      (D_SCO, Outcome);
               end loop;

               if MCDC_Coverage_Enabled
                 and then D_Bit_Alloc.Path_Bits_Base /= No_Bit_Id
               then
                  declare
                     Path_Count : constant Natural :=
                       SC_Obligations.Path_Count (D_SCO);
                  begin
                     for J in 1 .. Any_Bit_Id (Path_Count) loop
                        Bit_Maps.MCDC_Bits
                          (D_Bit_Alloc.Path_Bits_Base + J - 1) :=
                          (D_SCO, Natural (J - 1));
                     end loop;
                  end;
               end if;
            end;
         end loop;

         Set_Bit_Maps (UIC.CU, Bit_Maps);
      end;

      --  Insert automatic buffer dump calls, if requested

      if IC.Dump_Trigger /= Manual and then Unit_Info.Is_Main then
         Add_Auto_Dump_Buffers
           (IC   => IC,
            Info => Prj_Info,
            Main => UIC.Instrumented_Unit.Unit,
            URH  => Handle (Rewriter.Rewritten_Unit));
      end if;

      --  Emit the instrumented source file

      Rewriter.Apply;
   end Instrument_Source_File;

   -----------------
   -- Ensure_With --
   -----------------

   procedure Ensure_With (UIC : in out Unit_Inst_Context; Unit : Text_Type) is
      RH : Rewriting_Handle renames UIC.Rewriting_Context;
   begin
      if UIC.Withed_Units.Contains (Unit) then
         return;
      end if;

      Append_Child
        (Handle (UIC.Root_Unit.F_Prelude),
         Create_From_Template
           (RH,
            Template  => "with " & Unit & ";",
            Arguments => (1 .. 0 => No_Node_Rewriting_Handle),
            Rule      => With_Clause_Rule));

      UIC.Withed_Units.Include (Unit);
   end Ensure_With;

end Instrument.Sources;
