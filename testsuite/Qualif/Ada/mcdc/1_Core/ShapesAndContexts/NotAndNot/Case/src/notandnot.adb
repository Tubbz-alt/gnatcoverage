package body Notandnot is

   function F (A, B : Boolean) return Boolean is
   begin
      case (not A) and then (not B) is -- # evalStmt
         when True =>
            return True;   -- # decisionTrue
         when False =>
            return False;  -- # decisionFalse
      end case;
   end;
end;
