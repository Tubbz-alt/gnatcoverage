package body Notandnot is

   procedure Eval_F (A, B : Boolean; E : out Boolean) is
   begin
      E := (not A) and then (not B); -- # evalStmt
   end;

   function F (A, B : Boolean) return Boolean is
      Value : Boolean;
   begin
      Eval_F (A, B, Value); -- # returnValue
      return Value;                -- # returnValue
   end;
end;

