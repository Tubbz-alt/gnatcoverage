package body Notand is
   function F (A, B : Boolean) return Boolean is
   begin
      return (not A) and then B;  -- # evalStmt :o/e:
   end;
end;

