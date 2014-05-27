------------------------------------------------------------------------------
--                                                                          --
--                               GNATcoverage                               --
--                                                                          --
--                     Copyright (C) 2008-2013, AdaCore                     --
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

--  Package to handle traces at object/exec level

with Ada.Containers.Ordered_Sets;
with Elf_Arch;   use Elf_Arch;
with Interfaces; use Interfaces;
with System;     use System;

package Traces is

   Big_Endian_Host : constant Boolean := Default_Bit_Order = High_Order_First;
   --  Host order is determined by System.Default_Bit_Order

   subtype Pc_Type is Elf_Addr;
   No_PC : constant Pc_Type := 0;

   function Empty_Range (First, Last : Pc_Type) return Boolean is
      (Last - First >= 2 ** (Pc_Type'Size - 1));
   --  True if First .. Last denotes an empty range. Note that Pc_Type is a
   --  modular type, so this cannot be defined as (Last - First < 0).
   --
   package PC_Sets is new Ada.Containers.Ordered_Sets (Pc_Type);

   Pc_Type_Size : constant Unsigned_8 := Pc_Type'Size / System.Storage_Unit;
   --  Define the size of the PC.

   type Branch_Kind is (Br_None, Br_Call, Br_Ret, Br_Jmp);
   --  Type of a branch instruction.

   Machine : Unsigned_16 := 0;
   --  Target machine.  The value is the EM field defined by ELF.
   --  Set to 0 when unknown.

   --  Insn_State denotes the coverage of a range of machine instructions, i.e.
   --  coverage state for object-level coverage objectives: instruction
   --  coverage and object branch coverage.

   type Insn_State is
     (
      --  High level state of a trace entry

      Unknown,
      --  Not yet filled.

      Not_Covered,
      --  The code is not covered.  No instruction was executed.

      Covered,
      --  The code is fully covered (and there is no conditionnal branches).

      Branch_Taken,
      --  The code is covered, the last instruction is a branch and the
      --  branch was always taken.

      Fallthrough_Taken,
      --  The code is covered, the last instruction is a branch and the
      --  branch was never taken.

      Both_Taken
      --  The code is covered, the last instruction is a branch and the
      --  branch was both taken and not taken.
      );

   type Trace_Entry is record
      --  Trace entry as recorded in the trace database

      First, Last : Pc_Type;
      --  Code region for the trace

      Op : Unsigned_8;
      --  Op code that QEMU sets to give information about
      --  how this entry's section of object code has been left
      --  during execution (e.g. branch taken, branch fallthrough).
      --  The different values that this Op code may take are documented in
      --  qemu_traces.ads (e.g. Trace_Op_Block).

      State : Insn_State;
      --  Object coverage information for this code region (piggy-backed
      --  directly in the trace structure for optimization).

   end record;

   Bad_Trace : constant Trace_Entry := (First  => 1,
                                        Last   => 0,
                                        Op     => 0,
                                        State  => Unknown);
   --  Constant value for invalid traces

   procedure Dump_Op (Op : Unsigned_8);
   --  Display a string for OP.

   procedure Dump_Entry (E : Trace_Entry);
   --  Dump (on standard output) a trace entry.

   procedure Disp_State_Char (State : Insn_State);
   --  Display a character representing the state.

   procedure Get_Pc (Res : out Pc_Type; Line : String; Pos : in out Natural);
   --  Convert hexadecimal string contained in Line (Pos .. ???) to a Pc_Type.
   --  Store the result into RES, POS is the index past the last character
   --  accepted.

   type Insn_State_Map is array (Insn_State) of Character;
   Insn_State_Char : constant Insn_State_Map;
   --  One character representation of a state.
   --  Several states can be represented by the same character, if the
   --  difference is not meaningful to the user of xcov. Typically, Covered
   --  and Both_Taken: internally, it conveys the information that the
   --  corresponding instruction is a branch (or not); the user of xcov
   --  has no interest in this distinction.

private
   Insn_State_Char : constant Insn_State_Map :=
     (Unknown           => '?',
      Not_Covered       => '-',
      Covered           => '+',
      Branch_Taken      => '>',
      Fallthrough_Taken => 'v',
      Both_Taken        => '+');

end Traces;
