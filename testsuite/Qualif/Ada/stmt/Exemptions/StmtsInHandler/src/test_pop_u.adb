with Stacks, Support; use Stacks, Support;

-- Pop only, immediate underflow. Handler covered.

procedure Test_Pop_U is
   S : Stack (Size => 2);
   V : Integer;
begin
   Pop (S, V);
   Assert (Errcount (S) = 1);
end;

--# stacks.adb
-- /op_push/    l- ## s-
-- /op_pop/     l- ## s-
-- /test_oflow/   l- ## s-
-- /op_oflow/   l- ## s-
-- /test_uflow/   l+ ## 0
-- /op_uflow/   l+ ## 0
-- /op_handler/ l# ## x0

-- /push_decl/ l- ## s-
-- /push_body/ l- ## s-
-- /pop_decl/  l+ ## 0
-- /pop_body/  l+ ## 0
-- /err_body/  l+ ## 0
