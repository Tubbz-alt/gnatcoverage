package body Value is
   function Dovalue (X, Bomb : Boolean) return Boolean is
   begin
      if Bomb then            -- # __l!d!
         raise Program_Error; -- # __l-s-
      elsif X then       -- # evaluate
         return True;    -- # returnTrue
      else
         return False;   -- # returnFalse
      end if;
   end;

   function F (X : Boolean) return Boolean is
   begin
      return Dovalue (X, Bomb => False); -- # returnVal
   end;
end;
