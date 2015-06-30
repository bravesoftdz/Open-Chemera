{*******************************************************************************
This file is part of the Open Chemera Library.
This work is public domain (see README.TXT).
********************************************************************************
Author: Ludwig Krippahl
Date: 2014 02 21
Purpose:
  prepares docking orders and structure files, reads dock files


  for docking:
    Structure file options:

    -t target.pdb file to load (mandatory)
    -p probe.pdb file to load  (mandatory)
    -tout target.pdb file to save (mandatory if processing options)
    -pout probe.pdb fle to save (mandatory if processing options)
    -tchains target chains to select (e.g. ACD)
    -pchains probe chains to select
    -center
      center target and probe molecules
    -randomize
      randomize probe orientation
    -cut SurfaceCutoff
      cut cores on exposed residues with at least SurfaceCutoff exposed surface

    Job file options

    -j jobfile.xml (mandatory)

    -append
      append to jobs file instead of replacing (default)

    -contacts contactConstraintsFile
      file containing a list of residue contacts:
        chainID residueID chainID residueID distance num_models minoverlap
        the first residue is assumed to be target, the second is probe

    -unconstrained nummodels[:minoverlap]
      adds an unconstrained docking set. Nummodels is mandatory, minoverlap
      (after colon) is optional

    -maxcontacts num
      number of contacts to read from contacts file. If absent or 0 reads all


  Modifying job files

    -modify
      this flag is necessary to load and modify a job file
      { TODO : add an identifyer for the job to edit? }

  Scores options (can be added with -modify)


    -rmsd complex.pdb
      computes alfa-carbon rmsd to the complex. Currently only works if target, probe and
      complex are the same pdb file
      The superposition is made on the target molecule, the RMSD is computed for the probe

    -intrmsd complex.pdb
      computes the interface residues RMSD using the alfa carbon of all residues within
      5A (the interface) or the distance specified in intdist

    -intdist distance_in_A

    (both require a substitution matrix and a minimum alignment match)

    -submat filename

    -minalign (value from 0 to 1)


    -delscores
      deletes all additional scores
      TODO: enable specifying score id and deleting only those

  Reading results

    list models in each constraintset
    -table filename
    displays on screen, each constraint in one group of columns, then model id, overlap, other scores


    list all models
    -models filename
    displays on screen table with single list of models and all scores (removes duplicates)

    exports pdb
    -export filename
    -outfile filename.pdb
    -constraintset number
    -model  id
    -minscore scoreix
    -maxscore scoreix
      (if scoreix<0 then it refers to geometry)

    summary:
    -summary [h]
        outputs summary to screen, with headers if h
        -maxmodels NN;NN2;...
          maximum number of models to use per constraint
        -rmsdixs Nprobe;Nint
          indexes of the rmsd scores to be used for probe and interface




Requirements:
Revisions:
To do:
*******************************************************************************}

program dockprep;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}{$IFDEF UseCThreads}
  cthreads,
  {$ENDIF}{$ENDIF}
  Classes, SysUtils, docktasks, molecules, pdbmolecules, molfit,
  oclconfiguration, alignment, geomutils, stringutils, quicksort, geomhash,
  basetypes, base3ddisplay, progress, CustApp
  { you can add units after this };

type

  { TDockPrep }

  TDockPrep = class(TCustomApplication)
  protected
    FDockMan:TDockOrdersManager;
    procedure DoRun; override;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    procedure WriteHelp; virtual;
  end;

{ TDockPrep }

procedure TDockPrep.DoRun;
var
  f,maxcontacts:Integer;
  targetfile,probefile:string;
  targetout,probeout:string;
  jobfile:string;
  tchains,pchains:string;
  dormsd,center:Boolean;
  rotprobe,appendjobs:Boolean;
  submatfile:string;
  intdist,minalign:TFloat;
  contactfile:string;
  unconstrainedmodels,unconstrainedoverlap:Integer;
  submat:TSubMatrix;
  maxmodels:TIntegers;
  tmps:TSimpleStrings;
  fixedzrotation:TFloat;
  planemargin:TFLoat;
  LigandScore,InterfaceScore:Integer;


  procedure GetOptions;

  var
    tmp:string;
    tmps:TSimpleStrings;
    f:Integer;

  begin
    minalign:=0.9;
    fixedzrotation:=-1;
    planemargin:=-1;
    intdist:=5.0;

    targetfile:=GetOptionValue('t');
    probefile:=GetOptionValue('p');
    jobfile:=GetOptionValue('j');
    targetout:=GetOptionValue('tout');
    probeout:=GetOptionValue('pout');
    tchains:=GetOptionValue('tchains');
    pchains:=GetOptionValue('pchains');
    center:=HasOption('center');
    rotprobe:=HasOption('randomize');
    submatfile:=GetOptionValue('submat');
    dormsd:=false;
    if submatfile<>'' then
      begin
      submat:=ReadBLASTMatrix(submatfile);
      dormsd:=HasOption('rmsd') or HasOption('intrmsd') or HasOption('fullrmsd');
      end;


    appendjobs:=HasOption('append');
    contactfile:=GetOptionValue('contacts');
    maxcontacts:=0;
    tmp:=GetOptionValue('symmetry');
    if tmp<>'' then planemargin:=StrToFloat(tmp);
    tmp:=GetOptionValue('maxcontacts');
    if tmp<>'' then maxcontacts:=StrToInt(tmp);
    tmp:=GetOptionValue('minalign');
    if tmp<>'' then minalign:=StrToFloat(tmp);
    tmp:=GetOptionValue('intdist');
    if tmp<>'' then intdist:=StrToFloat(tmp);
    tmp:=GetOptionValue('fixedzrotation');
    if tmp<>'' then
      fixedzrotation:=StrToFloat(tmp)/180*pi;

    tmp:=GetOptionValue('maxmodels');
    if tmp<>'' then
        begin
        tmps:=SplitString(tmp,';');
        SetLength(maxmodels,Length(tmps));
        for f:=0 to High(tmps) do
          maxmodels[f]:=StrToInt(tmps[f]);
        end
    else
      begin
      SetLength(maxmodels,1);
      maxmodels[0]:=5000;
      end;
    tmp:=GetOptionValue('rmsdixs');
    if tmp<>'' then
        begin
        tmps:=SplitString(tmp,';');
        LigandScore:=StrToInt(tmps[0]);
        InterfaceScore:=StrToInt(tmps[1]);
        end
    else
      begin
      LigandScore:=-1;
      InterfaceScore:=-1;
      end;

    unconstrainedmodels:=5000;
    //No unconstrained models by default if
    if HasOption('contacts') or HasOption('symmetry') then
      unconstrainedmodels:=-1;
    unconstrainedoverlap:=200;
    tmp:=GetOptionValue('unconstrained');
    if tmp<>'' then
      begin
      tmps:=SplitString(tmp,':');
      unconstrainedmodels:=StrToInt(tmps[0]);
      if Length(tmps)>1 then
        unconstrainedoverlap:=StrToInt(tmps[1]);
      end;
  end;

  procedure Error(Msg:string);

  begin
    WriteLn();
    WriteLn(Msg);
    WriteLn();
    WriteLn(targetfile);
    WriteLn(probefile);
    WriteLn(targetout);
    WriteLn(probeout);
    WriteLn(tchains);
    WriteLn(pchains);
    WriteLn(center);
    WriteLn(rotprobe);;

    Terminate;
  end;

  procedure ShowDockResults(FileName:string);

  var
    table:TSimpleStrings;
    f:Integer;

  begin
    table:=ReadAsTable(FileName);
    for f:=0 to High(table) do
      WriteLn(table[f]);
  end;

  procedure ExportStructures;

  var
    outfile:string;
    constraintset,modelid,minscoreix,maxscoreix:Integer;
    model:TMolecule;
    runs:TDockRuns;

  begin
    outfile:=GetOptionValue('outfile');
    constraintset:=StrToInt(GetOptionValue('constraintset'));
    modelid:=StrToInt(GetOptionValue('model'));
    minscoreix:=StrToInt(GetOptionValue('minscore'));
    maxscoreix:=StrToInt(GetOptionValue('maxscore'));

    runs:=LoadOrders(jobfile);
    if HasOption('model') then
      model:=GetModel(runs[0],constraintset,modelid);
    SaveToPDB(model,outfile);
    FreeOrders(runs);
    model.Free;
  end;

  procedure AddRmsd;

  begin
    if HasOption('rmsd') then
      FDockMan.AddRMSDScore(GetOptionValue('rmsd'),submat,minalign,[rmsdFitTarget,rmsdScoreProbe],'Probe RMSD');
    if HasOption('intrmsd') then
      FDockMan.AddInterfaceRMSDScore(GetOptionValue('intrmsd'),intdist,submat,minalign);
    if HasOption('fullrmsd') then
      FDockMan.AddRMSDScore(GetOptionValue('fullrmsd'),submat,minalign,
        [rmsdFitTarget,rmsdFitProbe,rmsdScoreTarget,rmsdScoreProbe],'Full RMSD');
  end;

  procedure ExportModels;

  var
    infile:string;
    f,g:Integer;
    runs:TDockRuns;
    constixs,modelixs:TIntegers;
    s:string;
    sl:TStringList;
    scoreids:TSimpleStrings;

    function GetDescription(const DockRun:TDockRun;
        ConstIx,ModelIx:Integer;ScoreIds:TSimpleStrings):string;

    var f:Integer;

    begin
      Result:=IntToStr(ConstIx)+#9+IntToStr(ModelIx);
      with DockRun.ConstraintSets[ConstIx] do
        begin
        with DockModels[ModelIx] do
          begin
          Result:=Result+#9+FloatToStr(Rotation[0])
                        +#9+FloatToStr(Rotation[1])
                        +#9+FloatToStr(Rotation[2])
                        +#9+FloatToStr(Rotation[3]);
          Result:=Result+#9+FloatToStr(TransVec[0])
                        +#9+FloatToStr(TransVec[1])
                        +#9+FloatToStr(TransVec[2]);
          Result:=Result+#9+IntToStr(OverlapScore);
          for f:=0 to High(ScoreIds) do
            Result:=Result+#9+FloatToStrF(
              ScoreVal(DockRun.ConstraintSets[ConstIx],
                ModelIx,ScoreIds[f],-1), ffFixed,0,3);
          end;
        end;
    end;

  begin
    sl:=TStringList.Create;
    infile:=GetOptionValue('models');
    runs:=LoadOrders(infile);
    for f:=0 to High(runs) do
      begin
      sl.Add('Run '+IntToStr(f));
      if runs[f].ConstraintSets<>nil then
        begin
        scoreids:=ComputedScores(runs[f].ConstraintSets[0]);
        s:='Const.'+#9+'Model'+#9+'r'+#9+'i'+#9+'j'+#9+'k'+#9+'X'+#9+'Y'+#9+'Z'+#9+'Overlap';
        for g:=0 to High(scoreids) do
          s:=s+#9+scoreids[g];
        SortedModelList(runs[f], constixs, modelixs);
        sl.Add(s);
        for g:=0 to High(constixs) do
          sl.Add(GetDescription(runs[f],constixs[g],modelixs[g],scoreids));
        end;
      end;
    sl.SaveToFile(ChangeFileExt(infile,'')+'_table.tsv');
    FreeOrders(runs);
    sl.Free;
  end;


  procedure EditJob;

  begin
    FDockMan.LoadJobFile;
    if HasOption('delscores') then
      FDockMan.DeleteScores;
    if dormsd then
      begin
      FDockMan.PreparePartners;
      AddRmsd;
      end;
    FDockMan.SaveOrders(False);
  end;

  procedure Summary;

  var
    runs:TDockRuns;

    procedure WriteHeaders;

    var f:Integer;
        s:string;

    begin
      s:='';
      for f:=0 to High(maxmodels) do
        s:=s+'High '+IntToStr(maxmodels[f])+#9+'Good '+IntToStr(maxmodels[f])+#9+
          'Acceptable '+IntToStr(maxmodels[f])+#9+'Min RMSD '+IntToStr(maxmodels[f])+#9+
          'Min IntRMSD '+IntToStr(maxmodels[f])+#9;
      //WriteLn(#9+FlattenStrings(ComputedScores(runs[0].ConstraintSets[0]),#9+#9));
      WriteLn('Name'+#9+s+'Constraints TC'+#9+'Digitization TC'+#9+'Domain TC'+#9+'Scoring TC'+#9+
        'Total Rotations'+#9+'Done rotations');
    end;

    function Counts(NumModels:Integer):string;



    var
      c,m,hi,good,accept:Integer;
      lscore,iscore,miniscore,minlscore:TFloat;

    begin
      { TODO : Auto detect probe and interface rmsd scores if LigandScore or InterfaceScore <0 }
      {LigandScore=0;
      InterfaceScore=1;}

      hi:=0;
      good:=0;
      accept:=0;
      minlscore:=100000;
      miniscore:=100000;
      for c:=0 to High(runs[0].ConstraintSets) do
        for m:=0 to High(runs[0].ConstraintSets[c].ScoreResults[0].ScoreVals) do
          begin
          lscore:=runs[0].ConstraintSets[c].ScoreResults[LigandScore].ScoreVals[m];
          iscore:=runs[0].ConstraintSets[c].ScoreResults[InterfaceScore].ScoreVals[m];
          if lscore<minlscore then minlscore:=lscore;
          if iscore<miniscore then miniscore:=iscore;
          if (lscore<1) or (iscore<1) then Inc(hi)
          else if (lscore<5) or (iscore<2) then Inc(good)
          else if (lscore<10) or (iscore<4) then Inc(accept);
          if m>=NumModels then Break;
          end;

      Result:=IntToStr(hi)+#9+IntToStr(good)+#9+IntToStr(accept)+
              #9+FloatToStrF(minlscore,ffFixed,2,2)+#9+FloatToStrF(miniscore,ffFixed,2,2);
    end;

  var
    f:Integer;
    rep:string;

  begin
    runs:=LoadOrders(jobfile);
    if GetOptionValue('summary')='h' then
      WriteHeaders;
    rep:=ExtractFileName(jobfile)+#9;
    for f:=0 to High(maxmodels) do
      rep:=rep+Counts(maxmodels[f])+#9;
    WriteLn(rep,runs[0].Stats.ConstraintsTickCount,#9,
        runs[0].Stats.DigitizationTickCount,#9,
        runs[0].Stats.DomainTickCount,#9,
        runs[0].Stats.ScoringTickCount, #9,
        runs[0].TotalAngles,#9,
        runs[0].CompletedAngles);
    FreeOrders(runs);
  end;

begin
  Randomize;

  { TODO : Check best way of doing this }
  DecimalSeparator:='.';

  // parse parameters
  if HasOption('h','help') then begin
    WriteHelp;
    Terminate;
    Exit;
  end;


  { add your program here }
  LoadAtomData;
  LoadAAData;

  GetOptions;
  if jobfile='' then
    Error('Job file is mandatory.')
  else
    begin
    FDockMan:=TDockOrdersManager.Create(jobfile);
    if HasOption('summary') then
      Summary;
    if HasOption('export') then
      ExportStructures;
    if HasOption('models') then
      ExportModels;
    if HasOption('table') then
      ShowDockResults(GetOptionValue('table'));
    if HasOption('modify') then
      EditJob;
    if HasOption('t') and HasOption('p') then
      begin
      if ((tchains<>'') or (pchains<>'') or center or rotprobe) and
        ((targetout='') or (probeout='')) then
      Error('No output files for saving modified structures.')
      else
        begin
        FDockMan:=TDockOrdersManager.Create(jobfile);
        FDockMan.NewDockRun;
        FDockMan.PreparePartners(targetfile,probefile,tchains,pchains,center,rotprobe);
        if targetout<>'' then SaveToPDB(FDockMan.Target,targetout)
          else targetout:=targetfile;
        if probeout<>'' then SaveToPDB(FDockMan.Probe,probeout)
          else probeout:=probefile;
        FDockMan.SetPDBFiles(targetout,probeout);
        if dormsd then
          AddRmsd;
        if contactfile<>'' then
          FDockMan.AddResidueContacts(contactfile, maxcontacts);
        if fixedzrotation>=0 then
          FDOckMan.FixZRotation(fixedzrotation);
        if planemargin>0 then
          FDockMan.AddSymmetryConstraint(planemargin);
        if unconstrainedmodels>0 then
          FDockMan.AddNullConstraintSet(unconstrainedmodels,unconstrainedoverlap);
        FDockMan.SaveOrders(appendjobs);
        end;
      end;
      FDockMan.Free;
    end;

  // stop program loop
  Terminate;
end;

constructor TDockPrep.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  StopOnException:=True;
end;

destructor TDockPrep.Destroy;
begin
  inherited Destroy;
end;

procedure TDockPrep.WriteHelp;
begin
  { add your help code here }
  writeln('Usage: ',ExeName,' -t "target.pdb/target.pdb.gz" -p "probe.pdb/probe.pdb.gz" -j jobfile');
  WriteLn('Docking Options:');
  WriteLn('-tchains TargetChains');
  WriteLn('-pchains ProbeChains');
  WriteLn('  Specify which chains to use, generating new pdb files (-tout -pout)');
  WriteLn('-tout pdbfile');
  WriteLn('-pout pdbfile');
  WriteLn('  Mandatory if center, chains or randomize');
  WriteLn('-center : centers both target and probe');
  WriteLn('-randomize : randomizes orientation of probe');
  WriteLn('-fixedzrotation Angle');
  WriteLn('  probe will be rotated only this angle (degrees) for each rotation axis');
  WriteLn('-symmetry margin');
  WriteLn('  probe will be restricted to a plane perpendicular to the rotation axis, intersecting the center of the target');
  WriteLn('-contacts ContactConstraintsFile ');
  WriteLn('-minalign minimum alignment match for *rmsd, from 0 to 1');
  WriteLn('-submat substitution_matrix.txt');
  WriteLn('-rmsd template.pdb : scores probe by fitting target');
  WriteLn('-intrmsd template.pdb : scores interface region');
  WriteLn('-fullrmsd template.pdb :scores whole complex');
  WriteLn('-intdist interface distance, A');
  WriteLn('-append');
  WriteLn('-maxcontacts');
  WriteLn('-unconstrained models:minoverlap');
  WriteLn('  default is 5000 models, 200 of min overlap');
  WriteLn('  or no models if -contacts is specified');
  WriteLn('Processing existing files (requires existing -j file):');
  WriteLn('-summary: stats for scores');
  WriteLn('   -maxmodels: ; separated values for maximum number of models considered in summary');
  WriteLn('   -rmsdixs: ; separated values for the index of probe and interface rmsd');

  {  'export') then
    'models') then
    'table') then
    'modify') then

}

end;

var
  Application: TDockPrep;
begin
  Application:=TDockPrep.Create(nil);
  Application.Run;
  Application.Free;
end.

