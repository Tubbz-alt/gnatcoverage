package body Notand is

   function F (A, B : Boolean) return Boolean is
      E : boolean := (not A) and then B;  -- # evalStmt :o/e:
   begin
      return E;  -- # returnValue
   end;
end;



