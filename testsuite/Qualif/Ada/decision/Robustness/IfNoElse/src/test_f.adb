with Support, Checks; use Support, Checks;

procedure Test_F is
begin
   Check (Cond => False);
   Assert (N_Checks_Ok = 0 and then N_Checks = 1);
end;

--# checks.adb
-- /eval/   l! d!
-- /incOK/  l- s-
-- /incAll/ l+ 0
