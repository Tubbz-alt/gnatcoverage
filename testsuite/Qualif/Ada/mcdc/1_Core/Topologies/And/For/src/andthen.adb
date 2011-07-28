package body Andthen is

   function And_Then (A, B : Boolean) return Boolean is
      type Bmap is array (Boolean) of Boolean;  -- # decl
      Touched : Bmap := (others => False);  -- # decl
   begin
      for Value in False .. (A and then B) loop -- # evalStmt :o/e:
         Touched (Value) := True;              -- # returnValue
      end loop;
      return Touched (True);  -- # returnValue
   end;
end;
