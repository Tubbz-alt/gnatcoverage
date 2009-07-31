------------------------------------------------------------------------------
--                                                                          --
--                              Couverture                                  --
--                                                                          --
--                       Copyright (C) 2009, AdaCore                        --
--                                                                          --
-- Couverture is free software; you can redistribute it  and/or modify it   --
-- under terms of the GNU General Public License as published by the Free   --
-- Software Foundation; either version 2, or (at your option) any later     --
-- version.  Couverture is distributed in the hope that it will be useful,  --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHAN-  --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License  for more details. You  should  have  received a copy of the GNU --
-- General Public License  distributed with GNAT; see file COPYING. If not, --
-- write  to  the Free  Software  Foundation,  59 Temple Place - Suite 330, --
-- Boston, MA 02111-1307, USA.                                              --
--                                                                          --
------------------------------------------------------------------------------

--  Source Coverage Obligations

with Ada.Containers.Ordered_Maps;
with Ada.Containers.Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with Ada.Text_IO;       use Ada.Text_IO;

with SCOs;     use SCOs;
with Switches; use Switches;
with Types;    use Types;
with Get_SCOs;

package body SC_Obligations is

   subtype Source_Location is Sources.Source_Location;
   No_Location : Source_Location renames Sources.No_Location;
   --  (not SCOs.Source_Location)

   procedure Load_SCOs_From_ALI (ALI_Filename : String);
   --  Load SCOs from the named ALI file, populating a map of slocs to SCOs

   --------------------------------------------
   -- Management of binary decision diagrams --
   --------------------------------------------

   package BDD is
      --  Outgoing arcs from a BDD node

      type BDD_Node_Id is new Nat;
      No_BDD_Node_Id : constant BDD_Node_Id := 0;
      subtype Valid_BDD_Node_Id is BDD_Node_Id
      range No_BDD_Node_Id + 1 .. BDD_Node_Id'Last;

      type Destinations is record
         Dest_False, Dest_True : BDD_Node_Id;
      end record;

      --  BDD node kinds

      type BDD_Node_Kind is
        (Exit_False,
         --  Leaf (decision outcome is False)

         Exit_True,
         --  Leaf (decision outcome is True),

         Condition,
         --  Evaluate condition

         Jump);
         --  Indirect reference to another BDD node

      type BDD_Node (Kind : BDD_Node_Kind := Exit_False) is record
         case Kind is
            when Exit_False | Exit_True =>
               null;

            when Condition =>
               C_SCO : SCO_Id;
               --  Condition SCO

               Dests : Destinations;
               --  Outgoing arcs depending on this condition

            when Jump =>
               Dest : BDD_Node_Id := No_BDD_Node_Id;
               --   Next BDD node
         end case;
      end record;

      package BDD_Vectors is
        new Ada.Containers.Vectors
          (Index_Type   => Valid_BDD_Node_Id,
           Element_Type => BDD_Node);

      type BDD_Type is record
         Decision       : SCO_Id;
         Root_Condition : BDD_Node_Id := No_BDD_Node_Id;
         V              : BDD_Vectors.Vector;
      end record;

      procedure Allocate
        (BDD     : in out BDD_Type;
         Node    : BDD_Node;
         Node_Id : out BDD_Node_Id);
      --  Allocate a node within the given BDD with the given properties

      ------------------------------------
      -- Building the BDD of a decision --
      ------------------------------------

      --  The BDD is built while scanning the various items (conditions and
      --  operators) that make up a decision. The BDD is rooted at the first
      --  condition; each node is either the evaluation of a condition
      --  (with two outgoing arcs pointing to the continuation of the
      --  evaluation, depending on the condition's value), or a leaf indicating
      --  that the outcome of the decision has been fully determined. During
      --  BDD construction, a third type of node can appear, which is a Jump
      --  to another node (i.e. a node that has just one outgoing arc).

      --  The BDD is build by maintaining a stack of triples of BDD node ids.
      --  The node at the top of the stack designates the destinations that
      --  shall be assigned to the True and False outcomes of the subtree
      --  that is about to be scanned. The third node id, if not null, is
      --  the id of a Jump node that shall be connected to the root of the
      --  subtree about to be read.

      --  Initially, the destinations are the decision outcome leaves, and
      --  the origin is No_BDD_Node_Id.

      --  When a NOT operator is read, the True and False destinations of the
      --  top stack item are swapped.

      --  When an AND THEN operator is read, the top item is popped, and two
      --  items are pushed (corresponding to the two subtrees for the two
      --  operands). A new Jump node is allocated. The arcs for the right
      --  operand are:
      --
      --    Dest_True => Popped_Dest_True
      --      (if right op is True then overall subtree is True)
      --    Dest_False => Popped_Dest_False
      --      (if right op is True then overall subtree is False)
      --    Origin => Jump_Node
      --      (evaluation of right operand is attached as a destination
      --       of the left operand test)
      --
      --   and those for the left operand are:
      --    Dest_True => Jump_Node
      --      (if left op is True then evaluate right op)
      --    Dest_False => Popped_Dest_False
      --      (if right op is False then overall subtree is False)
      --    Origin => Popped_Origin
      --
      --  When an OR ELSE operator is read, a similar processing occurs.
      --
      --  When a condition is read, the top item is popped and a new Condition
      --  node is allocated. Its destinations are set from the popped item,
      --  and if an origin Jump node is present, then its destination is set
      --  to the id of the newly-allocated condition.
      --
      --  At the end of the processing for a decision, the stack is empty,
      --  and the BDD is simplified by replacing all references to jump nodes
      --  with direct references to their destinations.

      type Arcs is record
         Dests  : Destinations;
         --  Outgoing arcs for next condition

         Origin : BDD_Node_Id := No_BDD_Node_Id;
         --  Jump node referencing next condition
      end record;

      procedure Push (A : Arcs);
      function Pop return Arcs;
      --  Manage a stack of Arcs

      --  Construction of a BDD

      function Create (Decision : SCO_Id) return BDD_Type;
      --  Start construction of a new BDD for the given decision

      procedure Process_Not      (BDD : BDD_Type);
      procedure Process_And_Then (BDD : in out BDD_Type);
      procedure Process_Or_Else  (BDD : in out BDD_Type);
      --  Process NOT, AND THEN, OR ELSE operators

      procedure Process_Condition
        (BDD          : in out BDD_Type;
         Condition_Id : SCO_Id);
      --  Process condition

      procedure Completed (BDD : in out BDD_Type);
      --  Called when all items in decision have been processed

      procedure Dump_BDD (BDD : BDD_Type);
      --  Display BDD for debugging purposes

   end BDD;

   -------------------------------
   -- Main SCO descriptor table --
   -------------------------------

   use type Pc_Type;
   package PC_Sets is new Ada.Containers.Ordered_Sets (Pc_Type);

   type Tristate is (False, True, Unknown);

   type SCO_Descriptor (Kind : SCO_Kind := SCO_Kind'First) is record
      First_Sloc : Source_Location;
      --  First sloc (for a complex decision, taken from first condition)

      Last_Sloc  : Source_Location;
      --  Last sloc (unset for complex decisions)

      Parent : SCO_Id := No_SCO_Id;
      --  For a decision, pointer to the enclosing statement (or condition in
      --  the case of a nested decision), unset if decision is part of a
      --  flow control structure.
      --  For a condition, pointer to the enclosing decision.

      case Kind is
         when Condition =>
            Value : Tristate;
            --  Indicates whether this condition is always true, always false,
            --  or tested at run time (Unknown).

            PC_Set : PC_Sets.Set;
            --  Addresses of conditional branches testing this condition
            --  (if Value = Unknown).

            BDD_Node : BDD.BDD_Node_Id;
            --  Associated node in the decision's BDD

         when Decision =>
            Is_Complex_Decision : Boolean;
            --  True for complex decisions.
            --  Note that there is always a distinct Condition SCO descriptor,
            --  even for simple decisions.

            Decision_BDD : BDD.BDD_Type;
            --  BDD of the decision
         when others =>
            null;
      end case;
   end record;

   subtype Valid_SCO_Id is SCO_Id range No_SCO_Id + 1 .. SCO_Id'Last;

   package SCO_Vectors is
     new Ada.Containers.Vectors
       (Index_Type   => Valid_SCO_Id,
        Element_Type => SCO_Descriptor);
   SCO_Vector : SCO_Vectors.Vector;

   package body BDD is
      package Arcs_Stacks is
        new Ada.Containers.Vectors
          (Index_Type   => Natural,
           Element_Type => Arcs);

      Arcs_Stack : Arcs_Stacks.Vector;

      --------------
      -- Allocate --
      --------------

      procedure Allocate
        (BDD     : in out BDD_Type;
         Node    : BDD_Node;
         Node_Id : out BDD_Node_Id)
      is
      begin
         BDD.V.Append (Node);
         Node_Id := BDD.V.Last_Index;
      end Allocate;

      ---------------
      -- Completed --
      ---------------

      procedure Completed (BDD : in out BDD_Type) is
         use BDD_Vectors;

         procedure Patch_Jumps (Node : in out BDD_Node);
         --  Replace all destinations of Node that denote Jump nodes with
         --  the jump destination.

         -----------------
         -- Patch_Jumps --
         -----------------

         procedure Patch_Jumps (Node : in out BDD_Node) is
            procedure Patch_Jump (Dest : in out BDD_Node_Id);
            --  If Dest denotes a Jump node, replace it with its destination

            ----------------
            -- Patch_Jump --
            ----------------

            procedure Patch_Jump (Dest : in out BDD_Node_Id) is
               Dest_Node : constant BDD_Node := BDD.V.Element (Dest);
            begin
               if Dest_Node.Kind = Jump then
                  Dest := Dest_Node.Dest;
               end if;
               pragma Assert (BDD.V.Element (Dest).Kind /= Jump);
            end Patch_Jump;

         begin
            case Node.Kind is
               when Jump =>
                  Patch_Jump (Node.Dest);

               when Condition =>
                  Patch_Jump (Node.Dests.Dest_False);
                  Patch_Jump (Node.Dests.Dest_True);

               when others =>
                  null;
            end case;
         end Patch_Jumps;

         use type Ada.Containers.Count_Type;

      --  Start of processing for Completed

      begin
         --  Check that all arcs have been consumed

         pragma Assert (Arcs_Stack.Length = 0);

         --  Check that the root condition has been set

         pragma Assert (BDD.Root_Condition /= No_BDD_Node_Id);

         --  Iterate backwards on BDD nodes, replacing references to jump nodes
         --  with references to their destination.

         for J in reverse BDD.V.First_Index .. BDD.V.Last_Index loop
            BDD.V.Update_Element (J, Patch_Jumps'Access);
         end loop;

         if Verbose then
            Dump_BDD (BDD);
         end if;
      end Completed;

      --------------
      -- Dump_BDD --
      --------------

      procedure Dump_BDD (BDD : BDD_Type) is
         procedure Dump_Condition (N : BDD_Node_Id);
         --  Display one condition

         procedure Dump_Condition (N : BDD_Node_Id) is
            use Ada.Strings;

            Node : BDD_Node renames BDD.V.Element (N);
            Next_Condition : BDD_Node_Id := N + 1;

            procedure Put_Dest (Name : String; Dest : BDD_Node_Id);
            --  Dump one destination

            --------------
            -- Put_Dest --
            --------------

            procedure Put_Dest (Name : String; Dest : BDD_Node_Id) is
               Dest_Node : BDD_Node renames BDD.V.Element (Dest);
            begin
               Put ("    if " & Name & " then ");
               case Dest_Node.Kind is
                  when Exit_False =>
                     Put_Line ("return False");
                  when Exit_True =>
                     Put_Line ("return True");
                  when Condition =>
                     if Dest = Next_Condition then
                        Put_Line ("fallthrough");
                     else
                        Put_Line ("goto " & Dest'Img);
                     end if;
                  when others =>
                     raise Program_Error with "malformed BDD";
               end case;
            end Put_Dest;

         --  Start of processing for Dump_Condition

         begin
            pragma Assert (Node.Kind = Condition);

            while Next_Condition <= BDD.V.Last_Index
              and then BDD.V.Element (Next_Condition).Kind /= Condition
            loop
               Next_Condition := Next_Condition + 1;
            end loop;

            Put ("@" & Trim (N'Img, Side => Both)
                 & ": test " & Image (Node.C_SCO));

            case SCO_Vector.Element (Node.C_SCO).Value is
               when False =>
                  --  Static known False
                  Put_Line (" (always False)");

               when True =>
                  --  Static known True
                  Put_Line (" (always True)");

               when Unknown =>
                  --  Real runtime test
                  New_Line;
            end case;

            Put_Dest ("true ", Node.Dests.Dest_True);
            Put_Dest ("false", Node.Dests.Dest_False);

            if Next_Condition <= BDD.V.Last_Index then
               New_Line;
               Dump_Condition (Next_Condition);
            end if;
         end Dump_Condition;

      --  Start of processing for Dump_BDD

      begin
         Put_Line ("----- BDD for decision " & Image (BDD.Decision));
         Dump_Condition (BDD.Root_Condition);
         New_Line;
      end Dump_BDD;

      ------------
      -- Create --
      ------------

      function Create (Decision : SCO_Id) return BDD_Type is
         Exit_False_Id, Exit_True_Id : BDD_Node_Id;
      begin
         return BDD : BDD_Type do
            BDD.Decision := Decision;

            Allocate (BDD,
              BDD_Node'(Kind => Exit_False), Exit_False_Id);
            Allocate (BDD,
              BDD_Node'(Kind => Exit_True),  Exit_True_Id);

            Push
              (((Dest_False => Exit_False_Id,
                 Dest_True  => Exit_True_Id),
                Origin => No_BDD_Node_Id));
         end return;
      end Create;

      ----------------------
      -- Process_And_Then --
      ----------------------

      procedure Process_And_Then (BDD : in out BDD_Type) is
         A : constant Arcs := Pop;
         L : BDD_Node_Id;
      begin
         Allocate (BDD, BDD_Node'(Kind => Jump, Dest => No_BDD_Node_Id), L);

         --  Arcs for right operand: subtree is reached through label L if
         --  left operand is True.

         Push
           (((Dest_False => A.Dests.Dest_False,
              Dest_True  => A.Dests.Dest_True),
             Origin => L));

         --  Arcs for left operand

         Push
           (((Dest_False => A.Dests.Dest_False,
              Dest_True  => L),
             Origin => A.Origin));
      end Process_And_Then;

      -----------------
      -- Process_Not --
      -----------------

      procedure Process_Not (BDD : BDD_Type) is
         pragma Unreferenced (BDD);

         A : constant Arcs := Pop;
      begin
         --  Swap destinations of top arcs

         Push
           (((Dest_False => A.Dests.Dest_True,
              Dest_True  => A.Dests.Dest_False),
             Origin => A.Origin));
      end Process_Not;

      ---------------------
      -- Process_Or_Else --
      ---------------------

      procedure Process_Or_Else (BDD : in out BDD_Type) is
         A : constant Arcs := Pop;
         L : BDD_Node_Id;
      begin
         Allocate (BDD, BDD_Node'(Kind => Jump, Dest => No_BDD_Node_Id), L);

         --  Arcs for right operand: subtree is reached through label L if
         --  left operand is False.

         Push
           (((Dest_False => A.Dests.Dest_False,
              Dest_True  => A.Dests.Dest_True),
             Origin => L));

         --  Arcs for left operand

         Push
           (((Dest_False => L,
              Dest_True  => A.Dests.Dest_True),
             Origin => A.Origin));
      end Process_Or_Else;

      -----------------------
      -- Process_Condition --
      -----------------------

      procedure Process_Condition
        (BDD          : in out BDD_Type;
         Condition_Id : SCO_Id)
      is
         A : constant Arcs := Pop;
         N : BDD_Node_Id;
      begin
         Allocate (BDD,
           (Kind => Condition, C_SCO => Condition_Id, Dests => A.Dests), N);

         if A.Origin /= No_BDD_Node_Id then
            declare
               procedure Set_Dest (Origin_Node : in out BDD_Node);
               --  Set destination of Origin_Node to N

               --------------
               -- Set_Dest --
               --------------

               procedure Set_Dest (Origin_Node : in out BDD_Node) is
               begin
                  Origin_Node.Dest := N;
               end Set_Dest;
            begin
               BDD.V.Update_Element (A.Origin, Set_Dest'Access);
            end;

         else
            pragma Assert (BDD.Root_Condition = No_BDD_Node_Id);
            BDD.Root_Condition := N;
         end if;
      end Process_Condition;

      ---------
      -- Pop --
      ---------

      function Pop return Arcs is
      begin
         return Top : constant Arcs := Arcs_Stack.Last_Element do
            Arcs_Stack.Delete_Last;
         end return;
      end Pop;

      ----------
      -- Push --
      ----------

      procedure Push (A : Arcs) is
      begin
         Arcs_Stack.Append (A);
      end Push;

   end BDD;

   --------------------------
   -- Sloc -> SCO_Id index --
   --------------------------

   package Sloc_To_SCO_Maps is new Ada.Containers.Ordered_Maps
     (Key_Type     => Source_Location,
      Element_Type => SCO_Id);
   Sloc_To_SCO_Map : Sloc_To_SCO_Maps.Map;

   -----------------
   -- Add_Address --
   -----------------

   procedure Add_Address (SCO : SCO_Id; Address : Pc_Type) is
      procedure Update (SCOD : in out SCO_Descriptor);
      --  Add Address to SCOD's PC_Set

      ------------
      -- Update --
      ------------

      procedure Update (SCOD : in out SCO_Descriptor) is
      begin
         SCOD.PC_Set.Include (Address);
      end Update;
   begin
      SCO_Vector.Update_Element (SCO, Update'Access);
   end Add_Address;

   ----------------
   -- First_Sloc --
   ----------------

   function First_Sloc (SCO : SCO_Id) return Source_Location is
   begin
      return SCO_Vector.Element (SCO).First_Sloc;
   end First_Sloc;

   -----------
   -- Image --
   -----------

   function Image (SCO : SCO_Id) return String is
   begin
      if SCO = No_SCO_Id then
         return "<no SCO>";
      else
         declare
            SCOD : constant SCO_Descriptor := SCO_Vector.Element (SCO);
         begin
            return "SCO #" & Trim (SCO'Img, Side => Ada.Strings.Both) & ": "
              & SCO_Kind'Image (SCOD.Kind) & " at "
              & Image (SCOD.First_Sloc) & "-" & Image (SCOD.Last_Sloc);
         end;
      end if;
   end Image;

   ----------
   -- Kind --
   ----------

   function Kind (SCO : SCO_Id) return SCO_Kind is
   begin
      return SCO_Vector.Element (SCO).Kind;
   end Kind;

   ---------------
   -- Last_Sloc --
   ---------------

   function Last_Sloc (SCO : SCO_Id) return Source_Location is
   begin
      return SCO_Vector.Element (SCO).Last_Sloc;
   end Last_Sloc;

   ---------------
   -- Load_SCOs --
   ---------------

   procedure Load_SCOs (ALI_List_Filename : String_Acc) is
      ALI_List : File_Type;
   begin
      if ALI_List_Filename = null then
         return;
      end if;
      Open (ALI_List, In_File, ALI_List_Filename.all);
      while not End_Of_File (ALI_List) loop
         declare
            Line : String (1 .. 1024);
            Last : Natural;
         begin
            Get_Line (ALI_List, Line, Last);
            Load_SCOs_From_ALI (Line (1 .. Last));
         end;
      end loop;
   end Load_SCOs;

   ------------------------
   -- Load_SCOs_From_ALI --
   ------------------------

   procedure Load_SCOs_From_ALI (ALI_Filename : String) is
      Cur_Source_File : Source_File_Index := No_Source_File;
      Cur_SCO_Unit : SCO_Unit_Index;
      Last_Entry_In_Cur_Unit : Int;

      ALI_File : File_Type;
      Line : String (1 .. 1024);
      Last : Natural;
      Index : Natural;

      Current_Complex_Decision : SCO_Id := No_SCO_Id;
      Current_BDD : BDD.BDD_Type;
      --  BDD of current decision

      Last_SCO_Upon_Entry : constant SCO_Id := SCO_Vector.Last_Index;

      function Getc return Character;
      --  Consume and return one character from Line.
      --  Load next line if at end of line. Return ^Z if at end of file.

      function Nextc return Character;
      --  Peek at current character in Line

      procedure Skipc;
      --  Skip one character in Line

      ----------
      -- Getc --
      ----------

      function Getc return Character is
         Next_Char : constant Character := Nextc;
      begin
         Index := Index + 1;
         if Index > Last + 1 then
            Get_Line (ALI_File, Line, Last);
            Index := 1;
         end if;
         return Next_Char;
      end Getc;

      -----------
      -- Nextc --
      -----------

      function Nextc return Character is
      begin
         if End_Of_File (ALI_File) then
            return Character'Val (16#1a#);
         end if;
         if Index = Last + 1 then
            return ASCII.LF;
         end if;
         return Line (Index);
      end Nextc;

      -----------
      -- Skipc --
      -----------

      procedure Skipc is
         C : Character;
         pragma Unreferenced (C);
      begin
         C := Getc;
      end Skipc;

      procedure Get_SCOs_From_ALI is new Get_SCOs;

   --  Start of processing for Load_SCOs_From_ALI

   begin
      Open (ALI_File, In_File, ALI_Filename);
      Scan_ALI : loop
         if End_Of_File (ALI_File) then
            --  No SCOs in this ALI

            Close (ALI_File);
            return;
         end if;

         Get_Line (ALI_File, Line, Last);
         case Line (1) is
            when 'C' =>
               exit Scan_ALI;

            when others =>
               null;
         end case;
      end loop Scan_ALI;

      Index := 1;

      Get_SCOs_From_ALI;
      Close (ALI_File);

      --  Walk low-level SCO table for this unit and populate high-level tables

      Cur_SCO_Unit := SCO_Unit_Table.First;
      Last_Entry_In_Cur_Unit := SCOs.SCO_Table.First - 1;
      --  Note, the first entry in the SCO_Unit_Table is unused

      for Cur_SCO_Entry in
        SCOs.SCO_Table.First .. SCOs.SCO_Table.Last
      loop
         if Cur_SCO_Entry > Last_Entry_In_Cur_Unit then
            Cur_SCO_Unit := Cur_SCO_Unit + 1;
            pragma Assert
              (Cur_SCO_Unit in SCOs.SCO_Unit_Table.First
                            .. SCOs.SCO_Unit_Table.Last);
            declare
               SCOUE : SCO_Unit_Table_Entry
                         renames SCOs.SCO_Unit_Table.Table (Cur_SCO_Unit);
            begin
               pragma Assert (Cur_SCO_Entry in SCOUE.From .. SCOUE.To);
               Last_Entry_In_Cur_Unit := SCOUE.To;
               Cur_Source_File := Get_Index (SCOUE.File_Name.all);
            end;
         end if;

         pragma Assert (Cur_Source_File /= No_Source_File);
         Process_Entry : declare
            SCOE : SCOs.SCO_Table_Entry renames
                                     SCOs.SCO_Table.Table (Cur_SCO_Entry);

            function Make_Condition_Value return Tristate;
            --  Map condition value code (t/f/c) in SCOE.C2 to Tristate

            function Make_Sloc
              (SCO_Source_Loc : SCOs.Source_Location) return Source_Location;
            --  Build a Sources.Source_Location record from the low-level
            --  SCO Sloc info.

            procedure Update_Decision_BDD (SCOD : in out SCO_Descriptor);
            --  Set BDD of decision to Current_BDD

            procedure Update_Decision_Sloc (SCOD : in out SCO_Descriptor);
            --  Update the first sloc of a complex decision SCOD from that
            --  of its first condition (which is the current SCOE).

            --------------------------
            -- Make_Condition_Value --
            --------------------------

            function Make_Condition_Value return Tristate is
            begin
               case SCOE.C2 is
                  when 'f' => return False;
                  when 't' => return True;
                  when 'c' => return Unknown;

                  when others => raise Program_Error with
                       "invalid SCO condition value code: " & SCOE.C2;
               end case;
            end Make_Condition_Value;

            ---------------
            -- Make_Sloc --
            ---------------

            function Make_Sloc
              (SCO_Source_Loc : SCOs.Source_Location) return Source_Location
            is
            begin
               if SCO_Source_Loc = SCOs.No_Source_Location then
                  return Source_Location'
                    (Source_File => No_Source_File, others => <>);
               end if;

               return Source_Location'
                 (Source_File => Cur_Source_File,
                  Line        => Natural (SCO_Source_Loc.Line),
                  Column      => Natural (SCO_Source_Loc.Col));
            end Make_Sloc;

            -------------------------
            -- Update_Decision_BDD --
            -------------------------

            procedure Update_Decision_BDD (SCOD : in out SCO_Descriptor) is
            begin
               SCOD.Decision_BDD := Current_BDD;
            end Update_Decision_BDD;

            --------------------------
            -- Update_Decision_Sloc --
            --------------------------

            procedure Update_Decision_Sloc (SCOD : in out SCO_Descriptor) is
            begin
               if SCOD.First_Sloc.Source_File = No_Source_File then
                  SCOD.First_Sloc := Make_Sloc (SCOE.From);
               end if;
            end Update_Decision_Sloc;

         begin
            case SCOE.C1 is
               when 'S' =>
                  --  Statement

                  pragma Assert (Current_Complex_Decision = No_SCO_Id);
                  SCO_Vector.Append
                    (SCO_Descriptor'(Kind       => Statement,
                                     First_Sloc => Make_Sloc (SCOE.From),
                                     Last_Sloc  => Make_Sloc (SCOE.To),
                                     others     => <>));

               when 'I' | 'E' | 'W' | 'X' =>
                  --  Decision

                  pragma Assert (Current_Complex_Decision = No_SCO_Id);
                  SCO_Vector.Append
                    (SCO_Descriptor'(Kind       => Decision,
                                     First_Sloc => Make_Sloc (SCOE.From),
                                     Last_Sloc  => Make_Sloc (SCOE.To),
                                     Is_Complex_Decision =>
                                                   not SCOE.Last,
                                     others     => <>));
                  Current_BDD := BDD.Create (SCO_Vector.Last_Index);

                  if SCOE.Last then
                     --  Simple decision: no separate condition SCOE, create
                     --  condition immediately.

                     SCO_Vector.Append
                       (SCO_Descriptor'(Kind       => Condition,
                                        First_Sloc => Make_Sloc (SCOE.From),
                                        Last_Sloc  => Make_Sloc (SCOE.To),
                                        Parent     => SCO_Vector.Last_Index,
                                        Value      => Make_Condition_Value,
                                        others     => <>));
                     BDD.Process_Condition
                       (Current_BDD, SCO_Vector.Last_Index);

                     BDD.Completed (Current_BDD);
                     SCO_Vector.Update_Element
                       (Current_BDD.Decision, Update_Decision_BDD'Access);

                  else
                     --  Complex decision: conditions appear as distinct SCOEs

                     Current_Complex_Decision := SCO_Vector.Last_Index;
                  end if;

               when ' ' =>
                  --  Condition

                  pragma Assert (Current_Complex_Decision /= No_SCO_Id);

                  SCO_Vector.Update_Element
                    (Index   => Current_Complex_Decision,
                     Process => Update_Decision_Sloc'Access);

                  SCO_Vector.Append
                    (SCO_Descriptor'(Kind       => Condition,
                                     First_Sloc => Make_Sloc (SCOE.From),
                                     Last_Sloc  => Make_Sloc (SCOE.To),
                                     Parent     => Current_Complex_Decision,
                                     Value      => Make_Condition_Value,
                                     others     => <>));
                  BDD.Process_Condition (Current_BDD, SCO_Vector.Last_Index);

                  if SCOE.Last then
                     BDD.Completed (Current_BDD);
                     SCO_Vector.Update_Element
                       (Current_BDD.Decision, Update_Decision_BDD'Access);

                     Current_Complex_Decision := No_SCO_Id;
                  end if;

               when '!' =>
                  BDD.Process_Not (Current_BDD);

               when '&' =>
                  BDD.Process_And_Then (Current_BDD);

               when '|' =>
                  BDD.Process_Or_Else (Current_BDD);

               when '^' =>
                  raise Program_Error with
                    "forbidden usage of XOR operator in decision: "
                      & Image (Current_Complex_Decision);

               when 'T' =>
                  --  Exit point

                  null;

               when others =>
                  raise Program_Error
                    with "unexpected SCO entry code: " & SCOE.C1;
            end case;
         end Process_Entry;
      end loop;

      --  Build Sloc -> SCO index and set up Parent links

      for J in Last_SCO_Upon_Entry + 1 .. SCO_Vector.Last_Index loop
         declare
            First : Source_Location := SCO_Vector.Element (J).First_Sloc;

            procedure Process_Descriptor (SCOD : in out SCO_Descriptor);
            --  Set up parent link for SCOD at index J, and insert Sloc -> SCO
            --  map entry.

            procedure Process_Descriptor (SCOD : in out SCO_Descriptor) is
               Enclosing_SCO : constant SCO_Id := Slocs_To_SCO (First, First);
            begin
               if Verbose then
                  Put ("Processing: " & Image (J));
                  if SCOD.Kind = Decision then
                     if SCOD.Is_Complex_Decision  then
                        Put (" (complex)");
                     else
                        Put (" (simple)");
                     end if;
                  end if;
                  New_Line;
               end if;

               case SCOD.Kind is
                  when Decision =>
                     --  A Decision SCO must have a statement or (in the case
                     --  of a nested decision) a Condition SCO as its parent,
                     --  or no parent at all.

                     pragma Assert (Enclosing_SCO = No_SCO_Id
                                      or else
                                    Kind (Enclosing_SCO) /= Decision);
                     SCOD.Parent := Enclosing_SCO;

                     --  Decisions are not included in the sloc map, instead
                     --  their conditions are.

                     First := No_Location;
                  when Statement =>
                     --  A SCO for a (simple) statement is never nested

                     pragma Assert (Enclosing_SCO = No_SCO_Id);
                     null;

                  when Condition =>
                     --  Parent is already set to the enclosing decision
                     null;

               end case;

               if First /= No_Location then
                  Sloc_To_SCO_Map.Insert (First, J);
               end if;
            end Process_Descriptor;
         begin
            SCO_Vector.Update_Element (J, Process_Descriptor'Access);
         end;
      end loop;
   end Load_SCOs_From_ALI;

   ------------------------------
   -- Report_SCOs_Without_Code --
   ------------------------------

   procedure Report_SCOs_Without_Code is
      use SCO_Vectors;

      procedure Check_Condition (Cur : Cursor);
      --  Check whether this condition has an associated conditional branch
      ---------------------
      -- Check_Condition --
      ---------------------

      procedure Check_Condition (Cur : Cursor) is
         use Ada.Containers;

         SCOD : SCO_Descriptor renames Element (Cur);
      begin
         if SCOD.Kind = Condition and then SCOD.PC_Set.Length = 0 then
            Put_Line ("No conditional branch for " & Image (To_Index (Cur)));
         end if;
      end Check_Condition;
   begin
      SCO_Vector.Iterate (Check_Condition'Access);
   end Report_SCOs_Without_Code;

   ------------------
   -- Slocs_To_SCO --
   ------------------

   function Slocs_To_SCO
     (First_Sloc, Last_Sloc : Source_Location) return SCO_Id
   is
      use Sloc_To_SCO_Maps;
      Cur : constant Cursor := Sloc_To_SCO_Map.Floor (Last_Sloc);
      SCO : SCO_Id;

      function Range_Intersects
        (Range_First_Sloc, Range_Last_Sloc : Source_Location) return Boolean;
      --  True when First_Sloc .. Last_Sloc
      --  and Range_First_Sloc .. Range_Last_Sloc intersect.

      ----------------------
      -- Range_Intersects --
      ----------------------

      function Range_Intersects
        (Range_First_Sloc, Range_Last_Sloc : Source_Location) return Boolean
      is
      begin
         --  A range involving a No_Location bound is empty

         return Range_First_Sloc <= Last_Sloc
                  and then
                    First_Sloc <= Range_Last_Sloc
                  and then
                    Range_Last_Sloc /= No_Location;
      end Range_Intersects;

   begin
      if Cur /= No_Element then
         SCO := Element (Cur);
      else
         SCO := No_SCO_Id;
      end if;

      --  Cur is highest SCO range start before last

      while SCO /= No_SCO_Id loop
         declare
            SCOD : SCO_Descriptor renames SCO_Vector.Element (SCO);
         begin
            exit when Range_Intersects (SCOD.First_Sloc, SCOD.Last_Sloc);
         end;
         SCO := SCO_Vector.Element (SCO).Parent;
      end loop;

      return SCO;
   end Slocs_To_SCO;

end SC_Obligations;
