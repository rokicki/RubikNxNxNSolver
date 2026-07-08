unit UDThreaded;

// Parallel solver for the phase 1 "oblique" (x,y)/(y,x) center orbits.
// This is a cross-platform port of the original Windows-only thread pool
// (which used THandle/WaitForMultipleObjects): TThread.WaitFor is used
// instead, which is implemented on every FPC target including macOS/Cocoa
// via cthreads. The search algorithm itself (including the depth-10
// meet-in-the-middle pruning table and the first-move axis partitioning
// across worker threads) is unchanged from the original.

{$mode objfpc}{$H+}

interface

uses Classes, cubedefs, facecube;

const
  maxUDCenterThreads = 18; // Sollte ein Teiler von 54 sein

// Solves the (x,y) and (y,x) center orbits jointly, in parallel across
// maxUDCenterThreads worker threads partitioned by first-move axis.
// On success, leaves the solving move sequence in fc.fxymoves/fc.mvIdx,
// exactly like the other single-threaded MakeXxx search functions on
// faceletCube, and returns True.
function MakeUDCenterParallel(fc: faceletCube; x, y, maxDepth: integer): boolean;

implementation

uses SysUtils, globals, phase1_tables;

type
  makeUDCenter = class(TThread)
  private
    ax: integer; // 1. Drehung hat index 3*ax bis 3*ax+2
    x, y, max: integer; // Koordinaten des Clusters
    fc: faceletcube;
    procedure SearchUDCenter(ccx, slx, ccy, sly, togo: integer);
  protected
    procedure Execute; override;
  public
    constructor Create(a: integer; i, j, maxDepth: integer; flc: faceletcube);
  end;

var
  tud: array [0 .. maxUDCenterThreads - 1] of makeUDCenter; // Globale Variable

constructor makeUDCenter.Create(a: integer; i, j, maxDepth: integer; flc: faceletcube);
begin
  inherited Create(True); // nicht starten
  ax := a;
  x := i;
  y := j;
  max := maxDepth;
  fc := faceletcube.Create(flc);
end;

procedure makeUDCenter.Execute;
var
  idx, togo: integer;
begin
  togo := 0;
  fc.found := False;
  for idx := Low(fc.fxymoves) to High(fc.fxymoves) do
    fc.fxymoves[idx] := InitMove;

  while (fc.found = False) and not Terminated do
  begin
    if togo > max then
      Exit;
    fc.mvIdx := 0; // 1. free place in fxymoves
    SearchUDCenter(fc.Phase1CenterCoord(x, y), fc.Phase1Brick256Coord(x, y),
      fc.Phase1CenterCoord(y, x), fc.Phase1Brick256Coord(y, x), togo);
    Inc(togo);
  end;
end;

procedure makeUDCenter.SearchUDCenter(ccx, slx, ccy, sly, togo: integer);
var
  mv: moves;
  sc1: SymCoord32;
  syms: UInt8;
  n, altccx, altccy, altslx, altsly, key: integer;

  newccx, newccy, newslx, newsly: integer;
  aa: integer;
begin

  if togo = 10 then
  begin

    sc1 := UDCentCoordToSymCoord[ccx];
    syms := sc1.sym;
    n := 0;
    while (syms and (1 shl n)) = 0 do
      Inc(n);
    altccy := UDCentCoordSymTransform[ccy, n];
    altslx := UDBrick256CoordSymTransform[slx, n];
    key := (sc1.c_idx shl 8) + altslx;

    if UDStates10Table[key].used = 0 then
      Exit;
    if findLowerIndexUDStates10(key, altccy) <> -1 then
      exit;


    sc1 := UDCentCoordToSymCoord[ccy]; //exchange x and y and apply once more
    syms := sc1.sym;
    n := 0;
    while (syms and (1 shl n)) = 0 do
      Inc(n);
    altccx := UDCentCoordSymTransform[ccx, n];
    altsly := UDBrick256CoordSymTransform[sly, n];
    key := (sc1.c_idx shl 8) + altsly;

    if UDStates10Table[key].used = 0 then
      Exit;
    if findLowerIndexUDStates10(key, altccx) <> -1 then
      exit;

  end;
  if ((UDCentBrick256Prun[B_24_8 * slx + ccx] > togo) or
    (UDCentBrick256Prun[B_24_8 * sly + ccy] > togo)) then
    Exit;



  if togo = 0 then
  begin
    fc.found := True;
    for aa := 0 to maxUDCenterThreads - 1 do
      tud[aa].Terminate; // alle Threads beenden
  end
  else
  begin
    if Terminated then
      Exit;

    if stopProgram = True then
    begin
      for aa := 0 to maxUDCenterThreads - 1 do
        tud[aa].Terminate; // alle Threads beenden
      Exit;
    end;

    mv := InitMove;
    while True do
    begin
      if fc.mvIdx = 0 then
      begin
        mv := nextMovePhase1[NoMove, mv];
        if not (Ord(mv) >= 3 * ax) and (Ord(mv) < 3 * ax + 3) and (mv < NoMove)
        // +3: 54/18
        then
          continue;
        // nur dieser teil wird für den 1. Zug akzeptiert
      end
      else
        mv := nextMovePhase1[fc.fxymoves[fc.mvIdx - 1], mv];
      if (mv < xU1) and not UDfaceMoveAllowed[slx, Ord(mv)] then
        continue;

      if mv = NoMove then
      begin
        Exit;
      end
      else
      begin
        case mv of
          fU1..fB3:
          begin
            newccx := UDCenterMove[ccx, Ord(mv)];
            newccy := UDCenterMove[ccy, Ord(mv)];
            newslx := slx;
            newsly := sly;
          end;
          xU1..xB3:
          begin
            newccx := UDCenterMove[ccx, Ord(mv)];
            newslx := UDBrick256Move[slx, Ord(mv)];
            newccy := UDCenterMove[ccy, Ord(mv) + 18];
            newsly := UDBrick256Move[sly, Ord(mv) + 18];
          end;
          yU1..yB3:
          begin
            newccx := UDCenterMove[ccx, Ord(mv)];
            newslx := UDBrick256Move[slx, Ord(mv)];
            newccy := UDCenterMove[ccy, Ord(mv) - 18];
            newsly := UDBrick256Move[sly, Ord(mv) - 18];
          end;
        end;

        fc.fxymoves[fc.mvIdx] := mv;
        Inc(fc.mvIdx);
        SearchUDCenter(newccx, newslx, newccy, newsly, togo - 1);

        if (fc.found) or Terminated then
          // kehre zurück, ohne mvIdx zu verändern
          Exit;
        Dec(fc.mvIdx);
      end;
    end;

  end;

end;

function MakeUDCenterParallel(fc: faceletCube; x, y, maxDepth: integer): boolean;
var
  aa, k: integer;
begin
  for aa := 0 to maxUDCenterThreads - 1 do
  begin
    tud[aa] := makeUDCenter.Create(aa, x, y, maxDepth, fc);
    tud[aa].FreeOnTerminate := False;
  end;
  for aa := 0 to maxUDCenterThreads - 1 do
    tud[aa].Start;

  // portable equivalent of WaitForMultipleObjects(..., True, INFINITE):
  // wait until every worker has terminated
  for aa := 0 to maxUDCenterThreads - 1 do
    tud[aa].WaitFor;

  fc.mvIdx := -1; // signalisiert keine Lösung
  for aa := 0 to maxUDCenterThreads - 1 do
    if tud[aa].fc.found = True then
    begin
      fc.mvIdx := tud[aa].fc.mvIdx;
      for k := 0 to tud[aa].fc.mvIdx - 1 do
        fc.fxymoves[k] := tud[aa].fc.fxymoves[k];
      break;
    end;

  for aa := 0 to maxUDCenterThreads - 1 do
  begin
    tud[aa].fc.Free;
    tud[aa].Free;
  end;

  if fc.mvIdx < 0 then
    LogMsg(Format(
      'WARNING: MakeUDCenterParallel(%d,%d) found no solution within depth %d',
      [x, y, maxDepth]));

  Result := fc.mvIdx >= 0;
end;

end.
