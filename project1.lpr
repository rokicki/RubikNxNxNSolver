program project1;

// Command-line NxNxN centers-only solver.
// Builds a random cube of a given odd size, scrambles it, then solves
// phases 1..N (U/D centers to U/D face, F/B centers to F/B face,
// R/L/F/B centers to their exact face, U/D centers to their exact face)
// and reports the move count for each phase and the grand total.

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  cubedefs, facecube, globals, UDThreaded,
  phase1_tables, phase2_tables, phase3_tables, phase4_tables, phase5_tables;

type
  TColorArray24 = array [0 .. 23] of ColorIndex;

var
  fcube: faceletCube;
  cubeSize: integer;
  seed: longint;
  haveSeed: boolean;
  maxPhase: integer;
  scrambleMoves: integer;
  scrambleMode: string; // 'state' (default) or 'moves'

procedure PrintUsage;
begin
  WriteLn('Usage: project1 [options]');
  WriteLn('');
  WriteLn('  --size N       odd cube edge length (default 15)');
  WriteLn('  --seed N       RNG seed, for a reproducible scramble (default: time-based)');
  WriteLn('  --scramble-mode state|moves');
  WriteLn('                 ''state'' (default): directly assign each center orbit a');
  WriteLn('                 uniform random reachable coloring -- instant, regardless of size.');
  WriteLn('                 ''moves'': scramble via a long random walk of slice turns, like');
  WriteLn('                 the original GUI''s "Random" button (see --scramble).');
  WriteLn('  --scramble N   (--scramble-mode moves only) number of random slice turns');
  WriteLn('                 (default: size*size*3, same as the old GUI''s "Random" button)');
  WriteLn('  --phases N     solve phases 1..N, 1<=N<=4 (default 4). Phases build on');
  WriteLn('                 each other and cannot be solved out of order or in isolation.');
  WriteLn('  --verbose      print every individual orbit''s move sequence, not just totals');
  WriteLn('  --help         show this message');
  WriteLn('');
  WriteLn('The first time phase 2 and especially phase 3 run, they build multi-');
  WriteLn('gigabyte pruning tables that can take a long time to generate (this is');
  WriteLn('inherent to the algorithm, not this port). They are cached to disk in');
  WriteLn('the current directory and reused on subsequent runs.');
end;

function ElapsedSecs(start: TDateTime): double;
begin
  Result := (Now - start) * 86400.0;
end;

procedure ParseArgs;
var
  i: integer;
  s: string;
begin
  cubeSize := 15;
  haveSeed := False;
  seed := 0;
  scrambleMoves := -1;
  scrambleMode := 'state';
  maxPhase := 4;
  verbose := False;

  i := 1;
  while i <= ParamCount do
  begin
    s := ParamStr(i);
    if s = '--size' then
    begin
      Inc(i);
      cubeSize := StrToInt(ParamStr(i));
    end
    else if s = '--seed' then
    begin
      Inc(i);
      seed := StrToInt(ParamStr(i));
      haveSeed := True;
    end
    else if s = '--scramble' then
    begin
      Inc(i);
      scrambleMoves := StrToInt(ParamStr(i));
    end
    else if s = '--scramble-mode' then
    begin
      Inc(i);
      scrambleMode := ParamStr(i);
    end
    else if s = '--phases' then
    begin
      Inc(i);
      maxPhase := StrToInt(ParamStr(i));
    end
    else if s = '--verbose' then
      verbose := True
    else if (s = '--help') or (s = '-h') then
    begin
      PrintUsage;
      Halt(0);
    end
    else
    begin
      WriteLn('Unknown option: ', s);
      PrintUsage;
      Halt(1);
    end;
    Inc(i);
  end;

  if (cubeSize < 3) or (cubeSize mod 2 = 0) then
  begin
    WriteLn('--size must be an odd integer >= 3');
    Halt(1);
  end;
  if (maxPhase < 1) or (maxPhase > 4) then
  begin
    WriteLn('--phases must be between 1 and 4');
    Halt(1);
  end;
  if (scrambleMode <> 'state') and (scrambleMode <> 'moves') then
  begin
    WriteLn('--scramble-mode must be ''state'' or ''moves''');
    Halt(1);
  end;
end;

// Scrambles via a long random walk of slice turns, exactly like the
// original GUI's "Random" button (BRandomClick).
procedure ScrambleByMoves;
var
  i, a, slice, sz, mx: integer;
begin
  sz := fcube.size div 2;
  if scrambleMoves >= 0 then
    mx := scrambleMoves
  else
    mx := fcube.size * fcube.size * 3;
  LogMsg(Format('Scrambling %dx%dx%d cube with %d random slice turns...',
    [fcube.size, fcube.size, fcube.size, mx]));
  for i := 1 to mx do
  begin
    a := Random(6);
    slice := Random(sz);
    fcube.move(Axis(a), slice);
  end;
end;

// Shuffles the 24-element multiset {4xU,4xD,4xR,4xL,4xF,4xB} in place
// (Fisher-Yates).
procedure ShuffleColors24(var arr: TColorArray24);
var
  i, j: integer;
  tmp: ColorIndex;
begin
  for i := 23 downto 1 do
  begin
    j := Random(i + 1);
    tmp := arr[i];
    arr[i] := arr[j];
    arr[j] := tmp;
  end;
end;

// Assigns cluster (x,y) -- one physical orbit of 24 center facelets -- a
// uniformly random coloring out of all colorings with 4 facelets of each
// color. Every such coloring is reachable by legal moves (confirmed both by
// phase 1's pruning table reaching full coverage of its combined coordinate
// space, and independently by direct analysis), so this is equivalent to
// scrambling via random moves without needing to actually replay any.
procedure RandomizeOrbit(x, y: integer);
var
  colors: TColorArray24;
  i: integer;
begin
  for i := 0 to 3 do
    colors[i] := UCol;
  for i := 4 to 7 do
    colors[i] := DCol;
  for i := 8 to 11 do
    colors[i] := RCol;
  for i := 12 to 15 do
    colors[i] := LCol;
  for i := 16 to 19 do
    colors[i] := FCol;
  for i := 20 to 23 do
    colors[i] := BCol;
  ShuffleColors24(colors);
  for i := 0 to 23 do
    fcube.setClusterColorIndex(x, y, i, colors[i]);
end;

// Directly synthesizes a random (but solvable) state of every center orbit,
// instead of replaying a long walk of random moves. Every orbit on the cube
// is randomized independently and instantly; corners/edges are left alone
// since this solver never looks at them. See RandomizeOrbit for the three
// distinct orbit shapes this loop structure mirrors -- exactly the same
// "+cross" / oblique / "x-cross" split the four solve phases use.
procedure RandomizeCenters;
var
  i, j, half, n: integer;
begin
  half := fcube.size div 2;
  n := 0;
  LogMsg(Format(
    'Randomizing %dx%dx%d center orbits directly (uniform reachable state per orbit)...',
    [fcube.size, fcube.size, fcube.size]));

  // "+cross": cluster (i, half) == cluster (half, i), a single physical orbit
  for i := 1 to half - 1 do
  begin
    RandomizeOrbit(i, half);
    Inc(n);
  end;

  // oblique: cluster (i,j) and cluster (j,i) are two distinct physical orbits
  for i := 1 to half - 2 do
    for j := i + 1 to half - 1 do
    begin
      RandomizeOrbit(i, j);
      RandomizeOrbit(j, i);
      Inc(n, 2);
    end;

  // "x-cross": cluster (i,i), a single physical orbit (self-paired)
  for i := 1 to half - 1 do
  begin
    RandomizeOrbit(i, i);
    Inc(n);
  end;

  LogMsg(Format('Randomized %d center orbits.', [n]));
end;

// ------------------------------------------------------------------
// table construction (mirrors main.pas's FormCreate, minus the GUI ifdefs)
// ------------------------------------------------------------------

procedure BuildPhase1Tables;
var
  t: TDateTime;
begin
  t := Now;
  LogMsg('Building phase 1 tables...');
  createNextMovePhase1Table;
  createUDBrick256CoordSymTransTable;
  createUDFaceMoveAllowedTable;
  createUDCenterCoordToSymCoordTable;
  createUDCenterCoordSymTransTable;
  createUDCenterMoveTable;
  createUDBrick256MoveTable;
  createUDXCrossMoveTable;
  createDistanceTable;
  createUDPlusCross1PruningTable;
  createUDCentXBrick256CoordPruningTable;
  createUDXCrossPruningTable;
  LogMsg('Building depth-10 meet-in-the-middle table for the oblique orbit');
  LogMsg('search (can take a long time to generate the first time)...');
  createUDCentersSlice10;
  LogMsg(Format('Phase 1 tables ready (%.1f s).', [ElapsedSecs(t)]));
end;

procedure BuildPhase2Tables;
var
  t: TDateTime;
begin
  t := Now;
  LogMsg('Building phase 2 tables (this can take a while)...');
  createNextMovePhase2Table;
  createFBCenterMoveTable;
  createFBSliceMoveTable;
  createFBFaceMoveAllowedTable;
  createFBPlusCrossPruningTable;
  createFBFullCenterSliceCoordPruningTable;
  createFBXCrossMoveTable;
  createFBXCrossPruningTable;
  LogMsg(Format('Phase 2 tables ready (%.1f s).', [ElapsedSecs(t)]));
end;

procedure BuildPhase3Tables;
var
  t: TDateTime;
begin
  t := Now;
  LogMsg('Building phase 3 tables (the Brick702 pruning table alone can take');
  LogMsg('several hours and ~4 GB of RAM the first time it is generated)...');
  createNextMovePhase3Table;
  createPh3RLFBCenterMoveTable;
  createPh3RLFBXCrossMoveTable;
  createPh3Brick702CoordToSymCoordTable;
  createPh3RLFBCenterCoordSymTransTable;
  createPh3RLFBXCrossPruningTable;
  createPh3RLFBPlusCrossPruningTable;
  createPh3Brick702RLFBCentPruningTable;
  createDistanceTable;
  LogMsg(Format('Phase 3 tables ready (%.1f s).', [ElapsedSecs(t)]));
end;

procedure BuildPhase4Tables;
var
  t: TDateTime;
begin
  t := Now;
  LogMsg('Building phase 4 tables...');
  createNextMovePhase4Table;
  createPhase4RLFBBrickMoveTable;
  createPhase4UDBrickMoveTable;
  createPh4CenterMoveTable;
  createPhase4UDXCrossMoveTable;
  createPh4UDPlusCrossPruningTable;
  createPh4UDCentBrickPruningTable;
  createPh4UDXCrossPruningTable;
  LogMsg(Format('Phase 4 tables ready (%.1f s).', [ElapsedSecs(t)]));
end;

// ------------------------------------------------------------------
// solving (mirrors main.pas's BPhaseNClick handlers, single-threaded)
// ------------------------------------------------------------------

function AvgOf(ns, n: integer): double;
begin
  if n > 0 then
    Result := ns / n
  else
    Result := 0;
end;

function SolvePhase1: integer;
var
  i, j, total, ns, half: integer;
begin
  half := fcube.size div 2;
  total := 0;
  LogMsg('');
  LogMsg('Phase 1 - U,D centers to U or D faces:');

  LogMsg('+cross:');
  ns := 0;
  for i := 1 to half - 1 do
    if fcube.MakeUDPlusCross1(i) then
    begin
      Inc(total, fcube.mvIdx);
      Inc(ns, fcube.mvIdx);
      fcube.printMoves(i, half);
      fcube.applyMoves(i, half);
    end;
  LogMsg(Format('+cross phase 1: %d moves, %.2f moves/orbit average.',
    [ns, AvgOf(ns, half - 1)]));

  LogMsg('oblique (x,y) and (y,x) orbits:');
  ns := 0;
  for i := half - 2 downto 1 do
    for j := i + 1 to half - 1 do
      if MakeUDCenterParallel(fcube, i, j, 25) then
      begin
        Inc(total, fcube.mvIdx);
        Inc(ns, fcube.mvIdx);
        fcube.printMoves(i, j);
        fcube.applyMoves(i, j);
      end;
  LogMsg(Format('oblique orbits phase 1: %d moves, %.2f moves/orbit average.',
    [ns, AvgOf(ns, (half - 1) * (half - 2))]));

  LogMsg('xcross:');
  ns := 0;
  for i := 1 to half - 1 do
    if fcube.MakeUDXCross(i) then
    begin
      Inc(total, fcube.mvIdx);
      Inc(ns, fcube.mvIdx);
      fcube.printMoves(i, i);
      fcube.applyMoves(i, i);
    end;
  LogMsg(Format('x-cross phase 1: %d moves, %.2f moves/orbit average.',
    [ns, AvgOf(ns, half - 1)]));

  LogMsg(Format('Number of moves in phase 1: %d', [total]));
  Result := total;
end;

function SolvePhase2: integer;
var
  i, j, total, ns, half: integer;
begin
  half := fcube.size div 2;
  total := 0;
  LogMsg('');
  LogMsg('Phase 2 - RL, FB centers to RL, FB faces:');

  LogMsg('+cross:');
  ns := 0;
  for i := 1 to half - 1 do
    if fcube.MakeFBPlusCross(i) then
    begin
      Inc(total, fcube.mvIdx);
      Inc(ns, fcube.mvIdx);
      fcube.printMoves(i, half);
      fcube.applyMoves(i, half);
    end;
  LogMsg(Format('+cross phase 2: %d moves, %.2f moves/orbit average.',
    [ns, AvgOf(ns, half - 1)]));

  LogMsg('oblique (x,y) and (y,x) orbits:');
  ns := 0;
  for i := half - 2 downto 1 do
    for j := i + 1 to half - 1 do
      if fcube.MakeFBFullCenter(i, j) then
      begin
        Inc(total, fcube.mvIdx);
        Inc(ns, fcube.mvIdx);
        fcube.printMoves(i, j);
        fcube.applyMoves(i, j);
      end;
  LogMsg(Format('oblique orbits phase 2: %d moves, %.2f moves/orbit average.',
    [ns, AvgOf(ns, (half - 1) * (half - 2))]));

  LogMsg('xcross:');
  ns := 0;
  for i := 1 to half - 1 do
    if fcube.MakeFBXCross(i) then
    begin
      Inc(total, fcube.mvIdx);
      Inc(ns, fcube.mvIdx);
      fcube.printMoves(i, i);
      fcube.applyMoves(i, i);
    end;
  LogMsg(Format('x-cross phase 2: %d moves, %.2f moves/orbit average.',
    [ns, AvgOf(ns, half - 1)]));

  LogMsg(Format('Number of moves in phase 2: %d', [total]));
  Result := total;
end;

function SolvePhase3: integer;
var
  i, j, total, ns, half: integer;
begin
  half := fcube.size div 2;
  total := 0;
  LogMsg('');
  LogMsg('Phase 3 - R,L,F,B centers to their own faces:');

  LogMsg('+cross:');
  ns := 0;
  for i := 1 to half - 1 do
    if fcube.MakePh3RLFBPlusCross(i) then
    begin
      Inc(total, fcube.mvIdx);
      Inc(ns, fcube.mvIdx);
      fcube.printMoves(i, half);
      fcube.applyMoves(i, half);
    end;
  LogMsg(Format('+cross phase 3: %d moves, %.2f moves/orbit average.',
    [ns, AvgOf(ns, half - 1)]));

  LogMsg('oblique (x,y) and (y,x) orbits:');
  ns := 0;
  for i := half - 2 downto 1 do
    for j := i + 1 to half - 1 do
      if fcube.MakePh3Cent702(i, j) then
      begin
        Inc(total, fcube.mvIdx);
        Inc(ns, fcube.mvIdx);
        fcube.printMoves(i, j);
        fcube.applyMoves(i, j);
      end;
  LogMsg(Format('oblique orbits phase 3: %d moves, %.2f moves/orbit average.',
    [ns, AvgOf(ns, (half - 1) * (half - 2))]));

  LogMsg('xcross:');
  ns := 0;
  for i := 1 to half - 1 do
    if fcube.MakePh3XCross(i) then
    begin
      Inc(total, fcube.mvIdx);
      Inc(ns, fcube.mvIdx);
      fcube.printMoves(i, i);
      fcube.applyMoves(i, i);
    end;
  LogMsg(Format('x-cross phase 3: %d moves, %.2f moves/orbit average.',
    [ns, AvgOf(ns, half - 1)]));

  LogMsg(Format('Number of moves in phase 3: %d', [total]));
  Result := total;
end;

function SolvePhase4: integer;
var
  i, j, total, ns, half: integer;
begin
  half := fcube.size div 2;
  total := 0;
  LogMsg('');
  LogMsg('Phase 4 - U,D centers to their own faces:');

  LogMsg('+cross:');
  ns := 0;
  for i := 1 to half - 1 do
    if fcube.MakePh4UDPlusCross(i) then
    begin
      Inc(total, fcube.mvIdx);
      Inc(ns, fcube.mvIdx);
      fcube.printMoves(i, half);
      fcube.applyMoves(i, half);
    end;
  LogMsg(Format('+cross phase 4: %d moves, %.2f moves/orbit average.',
    [ns, AvgOf(ns, half - 1)]));

  LogMsg('oblique (x,y) and (y,x) orbits:');
  ns := 0;
  for i := half - 2 downto 1 do
    for j := i + 1 to half - 1 do
      if fcube.MakePh4UDCenters(i, j) then
      begin
        Inc(total, fcube.mvIdx);
        Inc(ns, fcube.mvIdx);
        fcube.printMoves(i, j);
        fcube.applyMoves(i, j);
      end;
  LogMsg(Format('oblique orbits phase 4: %d moves, %.2f moves/orbit average.',
    [ns, AvgOf(ns, (half - 1) * (half - 2))]));

  LogMsg('xcross:');
  ns := 0;
  for i := 1 to half - 1 do
    if fcube.MakePh4XCross(i) then
    begin
      Inc(total, fcube.mvIdx);
      Inc(ns, fcube.mvIdx);
      fcube.printMoves(i, i);
      fcube.applyMoves(i, i);
    end;
  LogMsg(Format('x-cross phase 4: %d moves, %.2f moves/orbit average.',
    [ns, AvgOf(ns, half - 1)]));

  LogMsg(Format('Number of moves in phase 4: %d', [total]));
  Result := total;
end;

var
  runStart: TDateTime;

begin
  ParseArgs;
  if haveSeed then
    RandSeed := longint(seed)
  else
    Randomize;

  runStart := Now;
  fcube := faceletCube.Create(cubeSize);
  // edgeParity/getEdgeCluster (used for an auxiliary parity coordinate as
  // early as phase 2's "+cross" step, not just phase 5) index into
  // fcube.ecls, which is only ever sized here in the original GUI -- do it
  // up front so it's ready no matter which phase needs it first.
  edgemx := fcube.size div 2;
  SetLength(fcube.ecls, edgemx + 1, 24);
  if scrambleMode = 'moves' then
    ScrambleByMoves
  else
    RandomizeCenters;

  grandTotal := 0;
  if maxPhase >= 1 then
  begin
    BuildPhase1Tables;
    Inc(grandTotal, SolvePhase1);
  end;
  if maxPhase >= 2 then
  begin
    BuildPhase2Tables;
    Inc(grandTotal, SolvePhase2);
  end;
  if maxPhase >= 3 then
  begin
    BuildPhase3Tables;
    Inc(grandTotal, SolvePhase3);
  end;
  if maxPhase >= 4 then
  begin
    BuildPhase4Tables;
    Inc(grandTotal, SolvePhase4);
  end;

  LogMsg('');
  LogMsg(Format('TOTAL: %d moves to fix the centers of the %dx%dx%d cube.',
    [grandTotal, cubeSize, cubeSize, cubeSize]));
  LogMsg(Format('Wall-clock time: %.1f s.', [ElapsedSecs(runStart)]));

  fcube.Free;
end.
