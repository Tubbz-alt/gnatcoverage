package body PandPor is

   function F (A, B, C : Boolean) return Boolean is
   begin
      loop
         exit when (A and then B) or else C;  -- # evalStmt :o/d:
         return False;                        -- # decisionFalse
      end loop;
      return True;                            -- # decisionTrue
   end;
end;
