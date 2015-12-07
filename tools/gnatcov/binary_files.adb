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

with Ada.Unchecked_Conversion;
with Interfaces; use Interfaces;

with GNAT.CRC32; use GNAT.CRC32;

package body Binary_Files is

   function Convert is new Ada.Unchecked_Conversion
     (System.Address, Binary_Content_Bytes_Acc);

   function Compute_CRC32 (File : Binary_File) return Unsigned_32;
   --  Compute and return the CRC32 of File

   --------
   -- Fd --
   --------

   function Fd (F : Binary_File) return File_Descriptor is
   begin
      return F.Fd;
   end Fd;

   ----------
   -- File --
   ----------

   function File (F : Binary_File) return Mapped_File is
   begin
      return F.File;
   end File;

   --------------
   -- Filename --
   --------------

   function Filename (F : Binary_File) return String is
   begin
      return F.Filename.all;
   end Filename;

   ----------------------
   -- Get_Nbr_Sections --
   ----------------------

   function Get_Nbr_Sections (File : Binary_File) return Section_Index is
   begin
      return File.Nbr_Sections;
   end Get_Nbr_Sections;

   procedure Set_Nbr_Sections (File : in out Binary_File; Nbr : Section_Index)
   is
   begin
      File.Nbr_Sections := Nbr;
   end Set_Nbr_Sections;

   ----------------
   -- Get_Status --
   ----------------

   function Get_Status (File : Binary_File) return Binary_File_Status is
   begin
      return File.Status;
   end Get_Status;

   ----------------
   -- Set_Status --
   ----------------

   procedure Set_Status
     (File : in out Binary_File; Status : Binary_File_Status) is
   begin
      File.Status := Status;
   end Set_Status;

   --------------
   -- Get_Size --
   --------------

   function Get_Size (File : Binary_File) return Long_Integer is
   begin
      return File.Size;
   end Get_Size;

   --------------------
   -- Get_Time_Stamp --
   --------------------

   function Get_Time_Stamp (File : Binary_File) return OS_Time is
   begin
      return File.Time_Stamp;
   end Get_Time_Stamp;

   ---------------
   -- Get_CRC32 --
   ---------------

   function Get_CRC32 (File : Binary_File) return Interfaces.Unsigned_32 is
   begin
      return File.CRC32;
   end Get_CRC32;

   ---------------
   -- Init_File --
   ---------------

   function Create_File
     (Fd : File_Descriptor; Filename : String_Access) return Binary_File is
   begin
      return Res : Binary_File := (Fd         => Fd,
                                   Filename   => Filename,
                                   File       => Invalid_Mapped_File,
                                   Status     => Status_Ok,
                                   Size       => File_Length (Fd),
                                   Nbr_Sections => 0,
                                   Time_Stamp => File_Time_Stamp (Fd),
                                   CRC32      => 0)
      do
         Res.File := Open_Read (Filename.all);
         Res.CRC32 := Compute_CRC32 (Res);
      end return;
   end Create_File;

   ----------------
   -- Close_File --
   ----------------

   procedure Close_File (File : in out Binary_File) is
   begin
      Close (File.File);
      File.Fd := Invalid_FD;

      --  Note: File.Filename may be referenced later on to produce error
      --  messages, so we don't deallocate it.
   end Close_File;

   -------------------
   -- Compute_CRC32 --
   -------------------

   function Compute_CRC32 (File : Binary_File) return Unsigned_32 is
      C              : CRC32;
      Content        : Mapped_Region := Read (File.File);
      Content_Length : constant Integer := Integer (Length (File.File));
   begin
      Initialize (C);
      Update (C, String (Data (Content).all (1 .. Content_Length)));
      Free (Content);
      return Get_Value (C);
   end Compute_CRC32;

   ------------------
   -- Make_Mutable --
   ------------------

   procedure Make_Mutable
     (File : Binary_File; Region : in out Mapped_Region) is
   begin
      --  If the region is already mutable (this can happen, for instance, if
      --  it was byte-swapped), do not risk losing changes remapping it.

      if not Is_Mutable (Region) then
         Read
           (File    => File.File,
            Region  => Region,
            Offset  => Offset (Region),
            Length  => File_Size (Last (Region)),
            Mutable => True);
      end if;
   end Make_Mutable;

   ------------------------
   -- Get_Section_Length --
   ------------------------

   function Get_Section_Length
     (File : Binary_File;
      Index : Section_Index) return Arch.Arch_Addr is
   begin
      raise Program_Error;
      return 0;
   end Get_Section_Length;

   ------------------
   -- Load_Section --
   ------------------

   function Load_Section
     (File : Binary_File; Index : Section_Index) return Mapped_Region is
      Res : Mapped_Region;
   begin
      raise Program_Error;
      return Res;
   end Load_Section;

   ----------
   -- Wrap --
   ----------

   function Wrap
     (Content     : System.Address;
      First, Last : Arch.Arch_Addr) return Binary_Content
   is
   begin
      return (Content => Convert (Content),
              First   => First,
              Last    => Last);
   end Wrap;

   --------------
   -- Relocate --
   --------------

   procedure Relocate
     (Bin_Cont  : in out Binary_Content;
      New_First : Arch.Arch_Addr) is
   begin
      Bin_Cont.Last := New_First + Length (Bin_Cont) - 1;
      Bin_Cont.First := New_First;
   end Relocate;

   ------------
   -- Length --
   ------------

   function Length (Bin_Cont : Binary_Content) return Arch.Arch_Addr is
   begin
      if Bin_Cont.First > Bin_Cont.Last then
         return 0;
      else
         return Bin_Cont.Last - Bin_Cont.First + 1;
      end if;
   end Length;

   ---------------
   -- Is_Loaded --
   ---------------

   function Is_Loaded (Bin_Cont : Binary_Content) return Boolean is
   begin
      return Bin_Cont.Content /= null;
   end Is_Loaded;

   ---------
   -- Get --
   ---------

   function Get
     (Bin_Cont : Binary_Content;
      Offset : Arch.Arch_Addr) return Interfaces.Unsigned_8 is
   begin
      return Bin_Cont.Content (Offset - Bin_Cont.First);
   end Get;

   -----------
   -- Slice --
   -----------

   function Slice
     (Bin_Cont    : Binary_Content;
      First, Last : Arch.Arch_Addr) return Binary_Content
   is
      RFirst : constant Arch.Arch_Addr :=
        (if Bin_Cont.First <= First
         then First
         else raise Constraint_Error with "First out of bounds");
      RLast : constant Arch.Arch_Addr :=
        (if Bin_Cont.Last >= Last
         then Last
         else raise Constraint_Error with "Last out of bounds");
   begin
      return
        (Content => Convert (Address_Of (Bin_Cont, RFirst)),
         First   => RFirst,
         Last    => RLast);
   end Slice;

   ----------------
   -- Address_Of --
   ----------------

   function Address_Of
     (Bin_Cont : Binary_Content;
      Offset   : Arch.Arch_Addr) return System.Address is
   begin
      if Bin_Cont.Content = null then
         return System.Null_Address;
      else
         return Bin_Cont.Content (Offset - Bin_Cont.First)'Address;
      end if;
   end Address_Of;

end Binary_Files;