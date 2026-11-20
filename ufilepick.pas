unit ufilepick;

{ A small full-screen file picker for the terminal browser, used by the
  Meal-Master import (F5) and to choose a recipe photo. It lists folders and
  the wanted files in a Far-style panel (name, size, modified), lets you mark
  several files (import), jump to "places", or type a path, and runs its own
  modal key/mouse loop on FPC's video, keyboard and mouse units (which the
  browser has already initialised).

  The listing, sorting and path helpers are plain functions so they can be
  unit-tested without a terminal. }

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  { what the picker offers: Meal-Master recipe files, or photos }
  TPickKind = (pkRecipes, pkImages);
  TPickResult = (prCancel, prChosen, prRemove);

  TPickEntry = record
    Name: string;           { file or folder name ('..' = parent) }
    IsDir: Boolean;
    Size: Int64;
    MTime: TDateTime;
  end;
  TPickEntries = array of TPickEntry;

{ True for a name the Meal-Master import reads: .mmf or .txt, any case. }
function IsRecipeFileName(const Name: string): Boolean;

{ True for a photo the library accepts: .jpg, .jpeg, .png or .webp, any case. }
function IsImageFileName(const Name: string): Boolean;

{ "512 B", "3.2 KiB", "1.1 MiB", "2.0 GiB". }
function FmtSize(N: Int64): string;

{ Local modification time of a file or folder (0 if it can't be read). }
function PickMTime(const Path: string): TDateTime;

{ The parent of Dir, or '' when Dir is a root (or has none). }
function ParentOf(const Dir: string): string;

{ Turn what the user typed into an absolute path: expands ~, keeps absolute
  paths, and resolves anything else against Dir. }
function ResolveTyped(const Dir, Txt: string): string;

{ List Dir: '..' first (unless Dir is a root), then folders, then files, each
  group sorted by name ignoring case. ShowAll false keeps only the files Kind
  asks for (IsRecipeFileName / IsImageFileName); ShowHidden false hides names
  starting with a dot. Returns False when Dir can't be read. }
function ListFolder(const Dir: string; Kind: TPickKind; ShowAll, ShowHidden: Boolean;
  out Entries: TPickEntries): Boolean;

{ Starting points for the places list: Names get a label, Paths the folder. }
procedure BuildPlaces(const LastDir: string; Names, Paths: TStrings);

{ Run the picker. StartDir is where it opens (falls back to the home folder);
  HasMouse says whether the mouse unit is active. Multi lets the user mark
  several files; OfferRemove adds an "r remove photo" choice. On prChosen,
  Files holds the absolute paths chosen; EndDir is always the folder the picker
  was in, so the caller can remember it. }
function PickFiles(Kind: TPickKind; const Title, StartDir: string;
  HasMouse, Multi, OfferRemove: Boolean; Files: TStrings;
  out EndDir: string): TPickResult;

{ The Meal-Master import's picker: True when files were chosen. }
function PickRecipeFiles(const StartDir: string; HasMouse: Boolean;
  Files: TStrings; out EndDir: string): Boolean;

implementation

uses
  SysUtils, DateUtils, video, keyboard, mouse, urender
  {$ifdef unix}, BaseUnix, Unix, unixutil, ctypes{$endif}
  {$ifdef windows}, Windows{$endif};

function IsRecipeFileName(const Name: string): Boolean;
var
  e: string;
begin
  e := LowerCase(ExtractFileExt(Name));
  Result := (e = '.mmf') or (e = '.txt');
end;

function IsImageFileName(const Name: string): Boolean;
var
  e: string;
begin
  e := LowerCase(ExtractFileExt(Name));
  Result := (e = '.jpg') or (e = '.jpeg') or (e = '.png') or (e = '.webp');
end;

function FmtSize(N: Int64): string;
begin
  if N < 1024 then Result := IntToStr(N) + ' B'
  else if N < 1024 * 1024 then Result := Format('%.1f KiB', [N / 1024])
  else if N < Int64(1024) * 1024 * 1024 then
    Result := Format('%.1f MiB', [N / (1024 * 1024)])
  else Result := Format('%.1f GiB', [N / (Int64(1024) * 1024 * 1024)]);
end;

{ On unix, FindFirst's timestamp applies today's UTC offset to every date,
  which is an hour off for dates in the other half of the DST year, so look
  the offset up for the file's own date instead. }
function PickMTime(const Path: string): TDateTime;
{$ifdef unix}
var
  st: Stat;
begin
  Result := 0;
  if FpStat(Path, st) <> 0 then Exit;
  Result := UnixToDateTime(st.st_mtime);
  if (Int64(st.st_mtime) >= 0) and (Int64(st.st_mtime) <= High(LongInt)) then
  begin
    GetLocalTimezone(cint(st.st_mtime));
    Result := Result + TZSeconds / 86400;
  end;
end;
{$else}
var
  age: LongInt;
begin
  Result := 0;
  age := FileAge(Path);
  if age <> -1 then Result := FileDateToDateTime(age);
end;
{$endif}

function ParentOf(const Dir: string): string;
var
  p, up: string;
begin
  Result := '';
  p := ExcludeTrailingPathDelimiter(Dir);
  if p = '' then Exit;                       { '/' }
  up := ExtractFileDir(p);
  if (up = '') or (up = p) then Exit;        { 'C:' }
  Result := IncludeTrailingPathDelimiter(up);
end;

function IsAbsolutePath(const P: string): Boolean;
begin
  Result := (P <> '') and ((P[1] = '/') or (P[1] = '\')
            or ((Length(P) >= 2) and (P[2] = ':')));
end;

function ResolveTyped(const Dir, Txt: string): string;
var
  t: string;
begin
  t := Trim(Txt);
  if (t <> '') and (t[1] = '~') and ((Length(t) = 1) or (t[2] = '/') or (t[2] = '\')) then
    t := ExcludeTrailingPathDelimiter(GetUserDir) + Copy(t, 2, Length(t));
  if t = '' then Result := Dir
  else if IsAbsolutePath(t) then Result := t
  else Result := IncludeTrailingPathDelimiter(Dir) + t;
end;

{ Insertion sort by name, ignoring case; the lists are folder-sized. }
procedure SortEntries(var A: TPickEntries);
var
  i, j: Integer;
  t: TPickEntry;
begin
  for i := 1 to High(A) do
  begin
    t := A[i];
    j := i - 1;
    while (j >= 0) and (CompareText(A[j].Name, t.Name) > 0) do
    begin
      A[j + 1] := A[j];
      Dec(j);
    end;
    A[j + 1] := t;
  end;
end;

function ListFolder(const Dir: string; Kind: TPickKind; ShowAll, ShowHidden: Boolean;
  out Entries: TPickEntries): Boolean;
var
  Info: TSearchRec;
  d: string;
  dirs, files: TPickEntries;
  e: TPickEntry;
  n, i: Integer;
begin
  Entries := nil;
  dirs := nil; files := nil;
  d := IncludeTrailingPathDelimiter(Dir);
  if not DirectoryExists(d) then Exit(False);
  Result := True;
  if FindFirst(d + '*', faAnyFile, Info) = 0 then
  begin
    repeat
      if (Info.Name = '.') or (Info.Name = '..') then Continue;
      if (not ShowHidden) and (Info.Name[1] = '.') then Continue;
      e.Name := Info.Name;
      e.IsDir := (Info.Attr and faDirectory) <> 0;
      e.Size := Info.Size;
      e.MTime := PickMTime(d + Info.Name);
      if e.IsDir then
      begin
        SetLength(dirs, Length(dirs) + 1);
        dirs[High(dirs)] := e;
      end
      else if ShowAll or ((Kind = pkRecipes) and IsRecipeFileName(Info.Name))
              or ((Kind = pkImages) and IsImageFileName(Info.Name)) then
      begin
        SetLength(files, Length(files) + 1);
        files[High(files)] := e;
      end;
    until FindNext(Info) <> 0;
    SysUtils.FindClose(Info);
  end;
  SortEntries(dirs);
  SortEntries(files);
  n := 0;
  if ParentOf(d) <> '' then n := 1;
  SetLength(Entries, n + Length(dirs) + Length(files));
  if n = 1 then
  begin
    Entries[0].Name := '..';
    Entries[0].IsDir := True;
    Entries[0].Size := 0;
    Entries[0].MTime := 0;
  end;
  for i := 0 to High(dirs) do Entries[n + i] := dirs[i];
  for i := 0 to High(files) do Entries[n + Length(dirs) + i] := files[i];
end;

{ --- places --- }

procedure AddPlace(Names, Paths: TStrings; const ALabel, APath: string);
begin
  if (APath = '') or not DirectoryExists(APath) then Exit;
  if Paths.IndexOf(APath) >= 0 then Exit;
  Names.Add(ALabel);
  Paths.Add(APath);
end;

procedure BuildPlaces(const LastDir: string; Names, Paths: TStrings);
{$ifdef unix}
var
  f: TextFile;
  line, mp: string;
  p: Integer;
{$endif}
{$ifdef windows}
var
  mask: DWORD;
  c: Char;
{$endif}
begin
  Names.Clear; Paths.Clear;
  AddPlace(Names, Paths, 'Last folder', LastDir);
  AddPlace(Names, Paths, 'Home', ExcludeTrailingPathDelimiter(GetUserDir));
  {$ifdef unix}
  AddPlace(Names, Paths, 'Root', '/');
  { mounted data drives }
  AssignFile(f, '/proc/self/mounts');
  {$I-} Reset(f); {$I+}
  if IOResult = 0 then
  begin
    while not Eof(f) do
    begin
      ReadLn(f, line);
      p := Pos(' ', line);
      if p = 0 then Continue;
      mp := Copy(line, p + 1, MaxInt);
      p := Pos(' ', mp);
      if p > 0 then mp := Copy(mp, 1, p - 1);
      mp := StringReplace(mp, '\040', ' ', [rfReplaceAll]);
      if (Copy(mp, 1, 5) = '/mnt/') or (Copy(mp, 1, 7) = '/media/') or
         (Copy(mp, 1, 11) = '/run/media/') then
        AddPlace(Names, Paths, 'Drive', mp);
    end;
    CloseFile(f);
  end;
  {$endif}
  {$ifdef windows}
  mask := GetLogicalDrives;
  for c := 'A' to 'Z' do
    if (mask and (DWORD(1) shl (Ord(c) - Ord('A')))) <> 0 then
      AddPlace(Names, Paths, 'Drive ' + c + ':', c + ':\');
  {$endif}
end;

{ ------------------------------------------------------------------------ }
{ The interactive picker                                                    }
{ ------------------------------------------------------------------------ }

const
  AttrNormal  = 7;                 { light gray on black }
  AttrDim     = 8;                 { dark gray on black }
  AttrTitle   = 15 or (1 shl 4);   { white on blue }
  AttrStatus  = 0 or (7 shl 4);    { black on light gray }
  AttrSel     = 0 or (3 shl 4);    { black on cyan }
  AttrHeading = 14;                { yellow }
  AttrDir     = 15;                { bright white }
  AttrMark    = 14 or (1 shl 4);   { yellow on blue: a marked file }

type
  THot = record
    x1, x2: Integer;
    Tag: string;
  end;

  TPicker = class
  private
    FKind: TPickKind;
    FTitle: string;
    FMulti, FOfferRemove, FRemove: Boolean;
    FDir: string;
    FEntries: TPickEntries;
    FSel, FTop: Integer;
    FMarked: TStringList;      { names marked in the current folder }
    FShowAll, FShowHidden: Boolean;
    FPlacesView: Boolean;      { the list shows places, not a folder }
    FPlaceNames, FPlacePaths: TStringList;
    FPathMode: Boolean;
    FPathText: string;
    FMsg: string;
    FLastDir: string;
    FHasMouse: Boolean;
    FDone, FOk: Boolean;
    FResult: TStrings;
    FZones: array of THot;
    function Rows: Integer;
    function Count: Integer;
    function IsFileAt(i: Integer): Boolean;
    function Reload(const Focus: string): Boolean;
    function CurName: string;
    procedure ChangeDir(const NewDir, Focus: string);
    procedure GoUp;
    procedure Move(Delta: Integer);
    procedure ToggleMark;
    procedure MarkAll;
    procedure ShowPlaces;
    procedure Activate;
    procedure Finish;
    procedure PathEnter;
    procedure Seg(var x: Integer; const Txt, Tag: string);
    procedure Draw;
    procedure Act(const Tag: string);
    procedure HandleKey(K: TKeyEvent);
    procedure HandleMouse(const M: TMouseEvent);
  public
    constructor Create(AKind: TPickKind; const ATitle, StartDir: string;
      AHasMouse, AMulti, AOfferRemove: Boolean; AResult: TStrings);
    destructor Destroy; override;
    function Run: TPickResult;
    property LastDir: string read FLastDir;
  end;

procedure PutCell(x, y: Integer; ch: Char; Attr: Byte);
begin
  if (x < 0) or (y < 0) or (x >= ScreenWidth) or (y >= ScreenHeight) then Exit;
  VideoBuf^[y * ScreenWidth + x] := Ord(ch) or (Attr shl 8);
end;

procedure PutStr(x, y: Integer; const S: string; Attr: Byte);
var
  i: Integer;
begin
  for i := 1 to Length(S) do PutCell(x + i - 1, y, S[i], Attr);
end;

procedure FillRow(y: Integer; Attr: Byte);
var
  x: Integer;
begin
  for x := 0 to ScreenWidth - 1 do PutCell(x, y, ' ', Attr);
end;

{ Pad or cut S to exactly W columns (a cut name ends in '~'). }
function Fit(const S: string; W: Integer): string;
begin
  if W <= 0 then Exit('');
  if Length(S) > W then Result := Copy(S, 1, W - 1) + '~'
  else Result := S + StringOfChar(' ', W - Length(S));
end;

constructor TPicker.Create(AKind: TPickKind; const ATitle, StartDir: string;
  AHasMouse, AMulti, AOfferRemove: Boolean; AResult: TStrings);
var
  d: string;
begin
  inherited Create;
  FKind := AKind;
  FTitle := ATitle;
  FMulti := AMulti;
  FOfferRemove := AOfferRemove;
  FResult := AResult;
  FHasMouse := AHasMouse;
  FMarked := TStringList.Create;
  FPlaceNames := TStringList.Create;
  FPlacePaths := TStringList.Create;
  d := StartDir;
  if (d = '') or not DirectoryExists(d) then
    d := ExcludeTrailingPathDelimiter(GetUserDir);
  if not DirectoryExists(d) then d := PathDelim;
  FDir := IncludeTrailingPathDelimiter(d);
  FLastDir := FDir;
  Reload('');
end;

destructor TPicker.Destroy;
begin
  FMarked.Free;
  FPlaceNames.Free;
  FPlacePaths.Free;
  inherited Destroy;
end;

function TPicker.Rows: Integer;
begin
  Result := ScreenHeight - 5;       { rows 3 .. H-3 }
  if Result < 1 then Result := 1;
end;

function TPicker.Count: Integer;
begin
  if FPlacesView then Result := FPlaceNames.Count else Result := Length(FEntries);
end;

function TPicker.IsFileAt(i: Integer): Boolean;
begin
  Result := (not FPlacesView) and (i >= 0) and (i < Length(FEntries))
            and (not FEntries[i].IsDir);
end;

function TPicker.Reload(const Focus: string): Boolean;
var
  i: Integer;
begin
  FPlacesView := False;
  Result := ListFolder(FDir, FKind, FShowAll, FShowHidden, FEntries);
  if not Result then FEntries := nil;
  FSel := 0;
  if Focus <> '' then
    for i := 0 to High(FEntries) do
      if SameText(FEntries[i].Name, Focus) then begin FSel := i; Break; end;
  FTop := 0;
  Move(0);
end;

function TPicker.CurName: string;
begin
  Result := '';
  if (not FPlacesView) and (FSel >= 0) and (FSel <= High(FEntries)) then
    Result := FEntries[FSel].Name;
end;

procedure TPicker.ChangeDir(const NewDir, Focus: string);
var
  nd, old: string;
begin
  nd := IncludeTrailingPathDelimiter(NewDir);
  old := FDir;
  FDir := nd;
  if not Reload(Focus) then
  begin
    FMsg := 'Cannot open ' + Disp(NewDir);
    FDir := old;
    Reload('');
    Exit;
  end;
  FMarked.Clear;      { marks belong to one folder }
  FLastDir := FDir;
end;

procedure TPicker.GoUp;
var
  p, here: string;
begin
  p := ParentOf(FDir);
  if p = '' then begin FMsg := 'Already at the top'; Exit; end;
  here := ExtractFileName(ExcludeTrailingPathDelimiter(FDir));
  ChangeDir(p, here);
end;

procedure TPicker.Move(Delta: Integer);
begin
  FSel := FSel + Delta;
  if FSel > Count - 1 then FSel := Count - 1;
  if FSel < 0 then FSel := 0;
  if FSel < FTop then FTop := FSel;
  if FSel > FTop + Rows - 1 then FTop := FSel - Rows + 1;
  if FTop < 0 then FTop := 0;
end;

procedure TPicker.ToggleMark;
var
  i: Integer;
begin
  if not FMulti then Exit;
  if not IsFileAt(FSel) then begin Move(1); Exit; end;
  i := FMarked.IndexOf(FEntries[FSel].Name);
  if i >= 0 then FMarked.Delete(i) else FMarked.Add(FEntries[FSel].Name);
  Move(1);
end;

procedure TPicker.MarkAll;
var
  i, files, marked: Integer;
begin
  if not FMulti then Exit;
  files := 0;
  for i := 0 to High(FEntries) do if not FEntries[i].IsDir then Inc(files);
  marked := FMarked.Count;
  FMarked.Clear;
  if files = 0 then Exit;
  if marked < files then      { not everything was marked yet: mark all }
    for i := 0 to High(FEntries) do
      if not FEntries[i].IsDir then FMarked.Add(FEntries[i].Name);
end;

procedure TPicker.ShowPlaces;
begin
  BuildPlaces(FLastDir, FPlaceNames, FPlacePaths);
  if FPlaceNames.Count = 0 then begin FMsg := 'No places found'; Exit; end;
  FPlacesView := True;
  FSel := 0; FTop := 0;
end;

procedure TPicker.Activate;      { Enter / Right / click on the selected row }
var
  e: TPickEntry;
begin
  if FPlacesView then
  begin
    if (FSel >= 0) and (FSel < FPlacePaths.Count) then
      ChangeDir(FPlacePaths[FSel], '');
    Exit;
  end;
  if (FSel < 0) or (FSel > High(FEntries)) then Exit;
  e := FEntries[FSel];
  if e.Name = '..' then GoUp
  else if e.IsDir then ChangeDir(FDir + e.Name, '')
  else Finish;     { Enter on a file chooses it (or the marked set) }
end;

{ Work out the files chosen: the marked ones, else the highlighted file, else
  (import only) the recipe files inside the highlighted folder. }
procedure TPicker.Finish;
var
  i: Integer;
  e: TPickEntry;
  inner: TPickEntries;
begin
  if FPlacesView then Exit;
  FResult.Clear;
  if FMulti and (FMarked.Count > 0) then
  begin
    for i := 0 to High(FEntries) do
      if (not FEntries[i].IsDir) and (FMarked.IndexOf(FEntries[i].Name) >= 0) then
        FResult.Add(FDir + FEntries[i].Name);
  end
  else if (FSel >= 0) and (FSel <= High(FEntries)) then
  begin
    e := FEntries[FSel];
    if not e.IsDir then FResult.Add(FDir + e.Name)
    else if FMulti and (e.Name <> '..') then
    begin
      if ListFolder(FDir + e.Name, FKind, False, FShowHidden, inner) then
        for i := 0 to High(inner) do
          if not inner[i].IsDir then
            FResult.Add(IncludeTrailingPathDelimiter(FDir + e.Name) + inner[i].Name);
    end;
  end;
  if FResult.Count = 0 then
  begin
    if FMulti then
      FMsg := 'Nothing to import: mark files with Space, or highlight a file or a folder of recipes'
    else
      FMsg := 'Highlight an image file and press Enter';
    Exit;
  end;
  FOk := True;
  FDone := True;
end;

procedure TPicker.PathEnter;
var
  p: string;
begin
  p := ResolveTyped(FDir, FPathText);
  if DirectoryExists(p) then
  begin
    FPathMode := False;
    ChangeDir(p, '');
  end
  else if FileExists(p) then
  begin
    FResult.Clear;
    FResult.Add(p);
    FLastDir := IncludeTrailingPathDelimiter(ExtractFileDir(p));
    FOk := True;
    FDone := True;
  end
  else
    FMsg := 'Not found: ' + Disp(p);
end;

procedure TPicker.Seg(var x: Integer; const Txt, Tag: string);
begin
  PutStr(x, ScreenHeight - 1, Txt, AttrStatus);
  SetLength(FZones, Length(FZones) + 1);
  FZones[High(FZones)].x1 := x;
  FZones[High(FZones)].x2 := x + Length(Txt) - 1;
  FZones[High(FZones)].Tag := Tag;
  Inc(x, Length(Txt));
end;

procedure TPicker.Draw;
var
  y, i, nw, x, W: Integer;
  e: TPickEntry;
  line, nm, sz, dt, hd: string;
  attr: Byte;
  marked: Boolean;
begin
  W := ScreenWidth;
  FZones := nil;
  for y := 0 to ScreenHeight - 1 do FillRow(y, AttrNormal);

  FillRow(0, AttrTitle);
  PutStr(1, 0, FTitle, AttrTitle);

  if FPlacesView then hd := 'Places' else hd := Disp(FDir);
  if Length(hd) > W - 2 then hd := '...' + Copy(hd, Length(hd) - (W - 6), W);
  PutStr(1, 1, hd, AttrHeading);

  nw := W - 2 - 1 - 9 - 1 - 16 - 1;
  if nw < 8 then nw := 8;
  if FPlacesView then
    PutStr(1, 2, Fit('  Place', nw + 2), AttrDim)
  else
    PutStr(1, 2, Fit('  Name', nw + 2) + ' ' + StringOfChar(' ', 9 - 4) + 'Size '
           + 'Modified', AttrDim);

  for i := FTop to FTop + Rows - 1 do
  begin
    if i >= Count then Break;
    y := 3 + i - FTop;
    if FPlacesView then
    begin
      line := '  ' + Fit(Disp(FPlaceNames[i] + '   ' + FPlacePaths[i]), W - 4);
      marked := False;
      attr := AttrNormal;
    end
    else
    begin
      e := FEntries[i];
      marked := (not e.IsDir) and (FMarked.IndexOf(e.Name) >= 0);
      nm := Disp(e.Name);
      dt := '';
      if e.Name = '..' then sz := '<UP--DIR>'
      else if e.IsDir then sz := '<DIR>'
      else sz := FmtSize(e.Size);
      if (e.Name <> '..') and (e.MTime > 0) then
        dt := FormatDateTime('yyyy-mm-dd hh:nn', e.MTime);
      if marked then line := ' *' else line := '  ';
      line := line + Fit(nm, nw) + ' ' + StringOfChar(' ', 9 - Length(sz)) + sz
              + ' ' + Fit(dt, 16);
      if marked then attr := AttrMark
      else if e.IsDir then attr := AttrDir
      else attr := AttrNormal;
    end;
    if i = FSel then
    begin
      attr := AttrSel;
      FillRow(y, AttrSel);
    end;
    PutStr(0, y, line, attr);
  end;
  if Count = 0 then PutStr(2, 3, '(empty)', AttrDim);

  { info / path row }
  if FPathMode then
  begin
    FillRow(ScreenHeight - 2, AttrSel);
    PutStr(1, ScreenHeight - 2, 'Go to: ' + FPathText + '_', AttrSel);
  end
  else if FMsg <> '' then
    PutStr(1, ScreenHeight - 2, Fit(FMsg, W - 2), AttrHeading)
  else
  begin
    if FShowAll then line := 'Showing all files'
    else if FKind = pkImages then line := 'Showing .jpg, .png and .webp images'
    else line := 'Showing .mmf and .txt files';
    if FMarked.Count > 0 then line := line + '    ' + IntToStr(FMarked.Count) + ' marked';
    PutStr(1, ScreenHeight - 2, line, AttrDim);
  end;

  { status bar: every label is clickable }
  FillRow(ScreenHeight - 1, AttrStatus);
  x := 0;
  if FMulti then
  begin
    Seg(x, ' Space mark ', 'mark');
    Seg(x, ' a all ', 'all');
  end;
  Seg(x, ' F2 places ', 'places');
  Seg(x, ' Tab filter ', 'filter');
  Seg(x, ' g path ', 'path');
  if FMulti then Seg(x, ' F5 import ', 'import')
  else Seg(x, ' Enter choose ', 'import');
  if FOfferRemove then Seg(x, ' r remove photo ', 'remove');
  Seg(x, ' Esc cancel ', 'cancel');
  UpdateScreen(True);
end;

procedure TPicker.Act(const Tag: string);
begin
  if Tag = 'mark' then ToggleMark
  else if Tag = 'all' then MarkAll
  else if Tag = 'places' then ShowPlaces
  else if Tag = 'filter' then
  begin
    FShowAll := not FShowAll;
    if not FPlacesView then Reload(CurName);
  end
  else if Tag = 'path' then begin FPathMode := True; FPathText := ''; end
  else if Tag = 'import' then Finish
  else if (Tag = 'remove') and FOfferRemove then
  begin
    FRemove := True; FOk := True; FDone := True;
  end
  else if Tag = 'cancel' then begin FOk := False; FDone := True; end;
end;

procedure TPicker.HandleKey(K: TKeyEvent);
var
  kind: Byte;
  code: Word;
  ch: Char;
begin
  FMsg := '';
  kind := GetKeyEventFlags(K) and $03;

  if (kind = kbFnKey) or (kind = kbPhys) then
  begin
    code := GetKeyEventCode(K);
    case code of
      kbdUp:     Move(-1);
      kbdDown:   Move(1);
      kbdPgUp:   Move(-Rows);
      kbdPgDn:   Move(Rows);
      kbdHome:   Move(-Count);
      kbdEnd:    Move(Count);
      kbdLeft:   if FPlacesView then FPlacesView := False else GoUp;
      kbdRight:  Activate;
      kbdInsert: ToggleMark;
      kbdF2:     Act('places');
      kbdF5:     if FMulti then Finish;
    end;
    Exit;
  end;

  ch := GetKeyEventChar(K);
  if FPathMode then
  begin
    case ch of
      #13: PathEnter;
      #27: FPathMode := False;
      #8, #127: if FPathText <> '' then Delete(FPathText, Length(FPathText), 1);
      #32..#126: FPathText := FPathText + ch;
    end;
    Exit;
  end;

  case ch of
    #13: Activate;
    #27, 'q', 'Q': begin FOk := False; FDone := True; end;
    #8, #127: if FPlacesView then FPlacesView := False else GoUp;
    #9: Act('filter');
    ' ': ToggleMark;
    'a', 'A': Act('all');
    'h', 'H':
      begin
        FShowHidden := not FShowHidden;
        if not FPlacesView then Reload(CurName);
      end;
    'i', 'I': if FMulti then Finish;
    'r', 'R': Act('remove');
    'g', 'G': Act('path');
    '/', '\', '~': begin FPathMode := True; FPathText := ch; end;
  end;
end;

procedure TPicker.HandleMouse(const M: TMouseEvent);
var
  i, y, idx: Integer;
begin
  if (M.Action and MouseActionDown) = 0 then Exit;
  if (M.Buttons and MouseButton4) <> 0 then begin Move(-3); Exit; end;
  if (M.Buttons and MouseButton5) <> 0 then begin Move(3); Exit; end;
  if (M.Buttons and MouseLeftButton) = 0 then Exit;
  FMsg := '';
  y := Integer(M.y);

  if y = ScreenHeight - 1 then
  begin
    for i := 0 to High(FZones) do
      if (Integer(M.x) >= FZones[i].x1) and (Integer(M.x) <= FZones[i].x2) then
      begin
        Act(FZones[i].Tag);
        Break;
      end;
    Exit;
  end;

  idx := FTop + (y - 3);
  if (y < 3) or (idx < 0) or (idx >= Count) then Exit;
  if idx <> FSel then
  begin
    FSel := idx;           { first click selects }
    Move(0);
  end
  else if FPlacesView or FEntries[idx].IsDir then
    Activate               { clicking the selected folder or place opens it }
  else if FMulti then
    ToggleMark             { clicking the selected file marks it }
  else
    Finish;                { single choice: clicking the selected file picks it }
end;

function TPicker.Run: TPickResult;
var
  M: TMouseEvent;
begin
  FOk := False;
  FRemove := False;
  FDone := False;
  repeat
    Draw;
    repeat
      if PollKeyEvent <> 0 then
      begin
        HandleKey(TranslateKeyEvent(GetKeyEvent));
        Break;
      end
      else if FHasMouse and PollMouseEvent(M) then
      begin
        GetMouseEvent(M);      { dequeue it, see the browser's main loop }
        HandleMouse(M);
        Break;
      end
      else
        Sleep(15);
    until False;
  until FDone;
  if not FOk then Result := prCancel
  else if FRemove then Result := prRemove
  else Result := prChosen;
end;

function PickFiles(Kind: TPickKind; const Title, StartDir: string;
  HasMouse, Multi, OfferRemove: Boolean; Files: TStrings;
  out EndDir: string): TPickResult;
var
  P: TPicker;
begin
  P := TPicker.Create(Kind, Title, StartDir, HasMouse, Multi, OfferRemove, Files);
  try
    Result := P.Run;
    EndDir := P.LastDir;
  finally
    P.Free;
  end;
end;

function PickRecipeFiles(const StartDir: string; HasMouse: Boolean;
  Files: TStrings; out EndDir: string): Boolean;
begin
  Result := PickFiles(pkRecipes, 'Import Meal-Master recipes', StartDir, HasMouse,
                      True, False, Files, EndDir) = prChosen;
end;

end.
