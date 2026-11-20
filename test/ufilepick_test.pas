program ufilepick_test;

{ Tests for the file picker's listing, sorting and path helpers (the
  interactive screen itself is checked separately through a pty). }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, ufilepick;

var
  Failures: Integer = 0;
  Checks: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Checks);
  if not Cond then begin Inc(Failures); WriteLn('FAIL: ', Msg); end;
end;

procedure Touch(const FileName, Text: string);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Text := Text;
    SL.SaveToFile(FileName);
  finally
    SL.Free;
  end;
end;

function Names(const E: TPickEntries): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(E) do
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + E[i].Name;
    if E[i].IsDir then Result := Result + '/';
  end;
end;

procedure TestHelpers;
begin
  Check(IsRecipeFileName('a.mmf'), '.mmf is a recipe file');
  Check(IsRecipeFileName('B.MMF'), '.MMF in capitals is a recipe file');
  Check(IsRecipeFileName('notes.txt'), '.txt is a recipe file');
  Check(not IsRecipeFileName('photo.jpg'), '.jpg is not');
  Check(not IsRecipeFileName('mmf'), 'a bare name is not');
  Check(IsImageFileName('a.jpg') and IsImageFileName('B.JPEG') and IsImageFileName('c.png')
        and IsImageFileName('d.WebP'), 'image extensions recognised');
  Check(not IsImageFileName('a.mmf') and not IsImageFileName('a.gif'), 'other files are not images');

  Check(FmtSize(0) = '0 B', 'size 0');
  Check(FmtSize(512) = '512 B', 'size bytes');
  Check(Pos('KiB', FmtSize(2048)) > 0, 'size KiB');
  Check(Pos('MiB', FmtSize(5 * 1024 * 1024)) > 0, 'size MiB');

  Check(ParentOf('/mnt/churn/') = '/mnt/', 'parent of a folder');
  Check(ParentOf('/mnt') = '/', 'parent of a top-level folder is the root');
  Check(ParentOf('/') = '', 'the root has no parent');

  Check(ResolveTyped('/tmp/x', '/etc/hosts') = '/etc/hosts', 'absolute path kept');
  Check(ResolveTyped('/tmp/x', 'a.mmf') = '/tmp/x/a.mmf', 'relative path joined');
  Check(ResolveTyped('/tmp/x', '  a.mmf  ') = '/tmp/x/a.mmf', 'typed path trimmed');
  Check(ResolveTyped('/tmp/x', '~') = ExcludeTrailingPathDelimiter(GetUserDir), '~ is home');
  Check(ResolveTyped('/tmp/x', '~/r.mmf') = ExcludeTrailingPathDelimiter(GetUserDir) + '/r.mmf',
        '~/ expands to home');
  Check(ResolveTyped('/tmp/x', '') = '/tmp/x', 'blank stays where it is');
end;

procedure TestList;
var
  root: string;
  E: TPickEntries;
  ok: Boolean;
begin
  root := GetTempDir + 'ufilepick_test_' + IntToStr(GetProcessID) + PathDelim;
  ForceDirectories(root + 'zeta');
  ForceDirectories(root + 'Alpha');
  ForceDirectories(root + '.hiddendir');
  Touch(root + 'b.mmf', 'x');
  Touch(root + 'A.MMF', 'x');
  Touch(root + 'c.txt', 'x');
  Touch(root + 'photo.jpg', 'x');
  Touch(root + '.secret.mmf', 'x');

  ok := ListFolder(root, pkRecipes, False, False, E);
  Check(ok, 'folder lists');
  Check(Names(E) = '../,Alpha/,zeta/,A.MMF,b.mmf,c.txt',
        'default: .. first, folders then recipe files, sorted ignoring case (got ' + Names(E) + ')');

  ListFolder(root, pkRecipes, True, False, E);
  Check(Names(E) = '../,Alpha/,zeta/,A.MMF,b.mmf,c.txt,photo.jpg',
        'show all adds the other files (got ' + Names(E) + ')');

  ListFolder(root, pkRecipes, False, True, E);
  Check(Pos('.hiddendir/', Names(E)) > 0, 'hidden folders shown on request');
  Check(Pos('.secret.mmf', Names(E)) > 0, 'hidden files shown on request');
  ListFolder(root, pkRecipes, False, False, E);
  Check(Pos('.secret', Names(E)) = 0, 'hidden files hidden by default');

  Check(E[2].IsDir and (E[2].Name = 'zeta'), 'IsDir set for folders');
  ListFolder(root, pkRecipes, False, False, E);
  Check(E[3].Size = 2, 'file size read (got ' + IntToStr(E[3].Size) + ')');
  Check(E[3].MTime > 0, 'file time read');

  ListFolder(root, pkImages, False, False, E);
  Check(Names(E) = '../,Alpha/,zeta/,photo.jpg', 'image kind lists only images (got ' + Names(E) + ')');

  ok := ListFolder(root + 'zeta', pkRecipes, False, False, E);
  Check(ok and (Names(E) = '../'), 'an empty folder lists just ..');
  ok := ListFolder(root + 'nope', pkRecipes, False, False, E);
  Check(not ok, 'a missing folder fails');

  ListFolder('/', pkRecipes, False, False, E);
  Check((Length(E) = 0) or (E[0].Name <> '..'), 'the root has no .. entry');

  DeleteFile(root + 'b.mmf'); DeleteFile(root + 'A.MMF'); DeleteFile(root + 'c.txt');
  DeleteFile(root + 'photo.jpg'); DeleteFile(root + '.secret.mmf');
  RemoveDir(root + 'zeta'); RemoveDir(root + 'Alpha'); RemoveDir(root + '.hiddendir');
  RemoveDir(root);
end;

procedure TestPlaces;
var
  N, P: TStringList;
begin
  N := TStringList.Create; P := TStringList.Create;
  try
    BuildPlaces('/tmp', N, P);
    Check(N.Count = P.Count, 'places: names and paths line up');
    Check(P.IndexOf('/tmp') >= 0, 'places: the last import folder is first-class');
    Check(N[0] = 'Last folder', 'places: last folder listed first');
    BuildPlaces('/no/such/folder', N, P);
    Check(P.IndexOf('/no/such/folder') < 0, 'places: a missing last folder is left out');
    Check(N.Count > 0, 'places: home is always there');
  finally
    N.Free; P.Free;
  end;
end;

begin
  TestHelpers;
  TestList;
  TestPlaces;
  WriteLn(Format('%d checks, %d failures', [Checks, Failures]));
  if Failures > 0 then Halt(1);
  WriteLn('OK');
end.
