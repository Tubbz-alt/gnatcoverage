------------------------------------------------------------------------------
--                                                                          --
--                              Couverture                                  --
--                                                                          --
--                     Copyright (C) 2008-2009, AdaCore                     --
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

with Ada.Directories;

with GNAT.Strings; use GNAT.Strings;

with Coverage;    use Coverage;
with Diagnostics; use Diagnostics;
with Strings;     use Strings;

package body Annotations.Report is

   type Final_Report_Type is limited record
      --  Final report information

      Name   : String_Access := null;
      --  Final report's file name

      File   : aliased File_Type;
      --  Handle to the final report
   end record;

   Final_Report : aliased Final_Report_Type;

   procedure Close_Report_File;
   --  Close the handle to the final report

   type Report_Pretty_Printer is new Pretty_Printer with record
      --  Pretty printer type for the final report

      Current_Filename : String_Access := null;
      --  When going through the lines of a source file,
      --  This is set to the current source file name.
   end record;

   --------------------------------------------------
   -- Report_Pretty_Printer's primitive operations --
   --      (inherited from Pretty_Printer)         --
   --------------------------------------------------

   procedure Pretty_Print_Start_File
     (Pp              : in out Report_Pretty_Printer;
      Source          : File_Info_Access;
      Stats           : Stat_Array;
      Has_Source      : Boolean;
      Skip            : out Boolean);

   procedure Pretty_Print_Start_Line
     (Pp : in out Report_Pretty_Printer;
      Line_Num : Natural;
      Info     : Line_Info_Access;
      Line : String);

   procedure Pretty_Print_End_File
     (Pp : in out Report_Pretty_Printer);

   -----------------------
   -- Close_Report_File --
   -----------------------

   procedure Close_Report_File is
   begin
      if Final_Report.Name /= null then
         Close (Final_Report.File);
         Free (Final_Report.Name);
      end if;
   end Close_Report_File;

   ----------------
   -- Get_Output --
   ----------------

   function Get_Output return File_Access is
   begin
      if Final_Report.Name /= null then
         return Final_Report.File'Access;
      else
         return Standard_Output;
      end if;
   end Get_Output;

   ---------------------
   -- Finalize_Report --
   ---------------------

   procedure Finalize_Report is
      Report_PP : Report_Pretty_Printer;
   begin
      Annotations.Generate_Report (Report_PP, False);
      Close_Report_File;
   end Finalize_Report;

   ----------------------
   -- Open_Report_File --
   ----------------------

   procedure Open_Report_File (Final_Report_Name : String) is
   begin
      Final_Report.Name := new String'(Final_Report_Name);

      if Final_Report.Name /= null then
         Create (Final_Report.File, Out_File, Final_Report.Name.all);
      end if;
   end Open_Report_File;

   ---------------------------
   -- Pretty_Print_End_File --
   ---------------------------

   procedure Pretty_Print_End_File (Pp : in out Report_Pretty_Printer) is
   begin
      null;
   end Pretty_Print_End_File;

   -----------------------------
   -- Pretty_Print_Start_File --
   -----------------------------

   procedure Pretty_Print_Start_File
     (Pp              : in out Report_Pretty_Printer;
      Source          : File_Info_Access;
      Stats           : Stat_Array;
      Has_Source      : Boolean;
      Skip            : out Boolean)
   is
      pragma Unreferenced (Has_Source);
      P : constant Counters := Get_Counters (Stats);
   begin
      if P.Fully /= P.Total then
         if Pp.Current_Filename /= null then
            Free (Pp.Current_Filename);
         end if;

         Pp.Current_Filename := new String'(Source.Full_Name.all);
         Skip := False;
      else
         Skip := True;
      end if;
   end Pretty_Print_Start_File;

   -----------------------------
   -- Pretty_Print_Start_Line --
   -----------------------------

   procedure Pretty_Print_Start_Line
     (Pp       : in out Report_Pretty_Printer;
      Line_Num : Natural;
      Info     : Line_Info_Access;
      Line     : String)
   is
      pragma Unreferenced (Line);

      use Ada.Directories;
      use Message_Vectors;

      Output : constant File_Access := Get_Output;
      Prefix : constant String := Simple_Name (Pp.Current_Filename.all) & ":"
                                    & Img (Line_Num) & ": ";

      procedure Put_Message (C : Cursor);
      --  Display message associated to Info

      -----------------
      -- Put_Message --
      -----------------

      procedure Put_Message (C : Cursor) is
         M : Message renames Element (C);
      begin
         if M.Kind /= Notice then
            Put (Output.all, Prefix);
            Put (Output.all, M.Msg.all);
            New_Line (Output.all);
         end if;
      end Put_Message;

   --  Start of processing for Pretty_Print_Start_Line

   begin
      for Level in Coverage_Level loop
         if Info.State (Level) /= Covered
           and then Info.State (Level) /= No_Code
         then
            Put (Output.all, Prefix);
            Put (Output.all, "line " & Info.State (Level)'Img & " for ");
            Put (Output.all, Level'Img);
            Put (Output.all, " coverage");
            New_Line (Output.all);

            Info.Messages.Iterate (Put_Message'Access);
            exit;
         end if;
      end loop;
   end Pretty_Print_Start_Line;

end Annotations.Report;
