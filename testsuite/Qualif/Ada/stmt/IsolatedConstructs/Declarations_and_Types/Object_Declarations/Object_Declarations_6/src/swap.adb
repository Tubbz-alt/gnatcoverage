--  This procedure contains access object declaration with explicit
--  initialization.
with Decls_Support; use Decls_Support;
with Support;       use Support;
procedure Swap (V1, V2 : in out Access_Coordinate) is
   Tmp : Access_Coordinate := V1;  -- # stmt
begin
   V1  := V2;                      -- # stmt
   V2  := Tmp;                     -- # stmt
end Swap;
