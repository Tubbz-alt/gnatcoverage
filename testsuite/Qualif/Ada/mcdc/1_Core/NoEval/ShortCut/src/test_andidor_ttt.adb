with Support, Andidor; use Support;

--  One evaluation with X True.
--  Inner decision True. Outer decision True.

procedure Test_Andidor_TTT is
begin
   Assert (Andidor (X => True, A => True, B => True) = True);
end;

--# andidor.adb
--  /eval/ l! ## dF-:"X", eF-:"A"
--  /true/  l+ ## 0
--  /false/ l- ## s-
