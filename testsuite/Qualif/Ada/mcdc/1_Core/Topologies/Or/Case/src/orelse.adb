package body Orelse is

   function Or_Else (A, B : Boolean) return Boolean is
   begin
      case A or else B is -- # evalStmt :o/e:
         when True =>
            return True;    -- # decisionTrue
         when False =>
            return False;   -- # decisionFalse
      end case;
   end;

end;
