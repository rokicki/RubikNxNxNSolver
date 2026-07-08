unit globals;

// Replaces the globals that used to live in the LCL form unit "main.pas"
// (removed as part of the GUI -> command-line port), plus simple console
// logging helpers to replace Form1.Memo1.Lines.Add / Application.ProcessMessages.

{$mode objfpc}{$H+}

interface

var
  stopProgram: boolean = False; // was a GUI "Abort" button flag; always False here
  grandTotal: integer = 0; // total number of moves for all phases
  edgemx: integer = 0; // maximum index for edge orbits (phase 5)
  verbose: boolean = False; // if True, print every individual move sequence

procedure LogMsg(const s: string);
procedure LogProgress(const s: string); // no trailing newline

implementation

procedure LogMsg(const s: string);
begin
  WriteLn(s);
end;

procedure LogProgress(const s: string);
begin
  Write(s);
end;

end.
