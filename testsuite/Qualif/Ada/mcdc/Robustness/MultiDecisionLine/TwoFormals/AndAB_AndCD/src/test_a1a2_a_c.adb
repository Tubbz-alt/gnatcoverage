with A1A2, Support; use A1A2, Support;

procedure Test_A1A2_A_C is
begin
   Process (A => True, B => True, C => True, D => True);
   Process (A => False, B => True, C => False, D => True);
end;

--# a1a2.adb
-- /evals/ l! c!:"B" # c!:"D"

