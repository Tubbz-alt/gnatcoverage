with Process;

procedure Test_Local_Inrange is
begin
   Process.Check_Inrange;
end;

--# process.adb
--  /in_decl/   l+ ## 0
--  /in_stmt/   l+ ## 0
--  /in_clause/ l. ## 0

--  /out_decl/   l- ## s-
--  /out_stmt/   l- ## s-
--  /out_clause/ l. ## 0

--# data.adb
--  /test_index/ l+ ## 0
--  /in_range/   l+ ## 0
--  /out_range/  l- ## s-
