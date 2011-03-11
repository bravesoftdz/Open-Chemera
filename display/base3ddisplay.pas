{*******************************************************************************
This file is part of the Open Chemera Library.
This work is public domain. Enjoy.
********************************************************************************
Author: Ludwig Krippahl
Date: 9.1.2011
Purpose:
  This is the abstract base interface for the Chemera 3D display.
  All such forms, windows, etc must implement this interface.
  Also includes utility functions (eg for colors, coords, etc)
Requirements:
  Must provide the basic functions for display
    Cylinder
    Sphere
    Colors and stuff
Revisions:
To do:
  Material specs (only color at present)
  Add textures
  Add lights
  Add zoom, clip, etc
  Add motion controls
*******************************************************************************}

unit base3ddisplay;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, basetypes;

const
  //Object type constants
  otSphere=0;
  otLine=1;
  otCilinder=2;
  otCuboid=3;



type
  TQuad=array[0..3] of Integer;     //vertex indexes for a quad
  TQuads=array of TQuad;

  TQuadMesh=record
    Faces:TQuads;
    Points:TOCCoords;
  end;


  TRGBAColor=array[0..3] of TOCFLoat;
  //TODO: decide on callback parameters (Clicked, etc)
  TBase3DOnMouse=procedure(ObjectId:Integer; Action:Integer);

  //Material specifications. Should have the most features implemented
  T3DMaterial=record
    Diffuse,Specular,Ambient:TRGBAColor;
    Texture:string;
  end;

  T3DObject=record
    case ObjecType:Integer of
      otSphere:(Rad:TOCFloat;sphC:TOCCoord);
      otLine:(linC1,linC2:TOCCoord);
      otCilinder:(cylC1,cylC2:TOCCoord;Rad1,Rad2:TOCFLoat);
      otCuboid:(cubTopLeft,cubBotRight:TOCCoord);
  end;

  T3DObjects=array of T3DObject;

  T3DObjectList=record
    Material:T3DMaterial;
    Objects:T3DObjects;
    end;

  //Display interface
  //TODO: fill in functions in paralel with GLUT window development
  IBase3DDisplay=interface
    procedure AddObjectList(ObjectList:T3DObjectList);
    procedure ClearObjectLists;
    procedure Compile;
      //for rendering, preparing display lists, etc. Depends on the engine
    procedure Resize(NewWidth,NewHeight:Integer);
    procedure Refresh;
      //refreshing currently rendered objects
    procedure SetQuality(Quality:Integer);
      //Render dependent. Set base quality for rendering (e.g. number of polygons)
  end;

function RGBAColor(R,G,B,A:TOCFloat):TRGBAColor;
function QuadSphere(Splits:Integer):TQuadMesh;     //faces=6*splits^4
function QuadCube:TQuadMesh;
function Quad(P1,P2,P3,P4:Integer):TQuad;
function DefaultMaterial:T3DMaterial;
function ColorMaterial(R,G,B,A:TOCFloat):T3DMaterial;

implementation

function RGBAColor(R,G,B,A:TOCFloat):TRGBAColor;

begin
  Result[0]:=R;
  Result[1]:=G;
  Result[2]:=B;
  Result[3]:=A;
end;

function Quad(P1,P2,P3,P4:Integer):TQuad;

begin
  Result[0]:=P1;
  Result[1]:=P2;
  Result[2]:=P3;
  Result[3]:=P4;
end;

function QuadCube:TQuadMesh;

var
  x,y,z,c:Integer;
  diag:Single;

begin
  diag:=1/Sqrt(0.75); //normalization
  with Result do
    begin
    SetLength(Result.Points,8);
    SetLength(Result.Faces,6);
    c:=0;
    for x:=0 to 1 do
      for y:=0 to 1 do
        for z:=0 to 1 do
        begin
          //cube of radius 1, centered in origin
          Points[c]:=Coord((x-0.5)*diag,(y-0.5)*diag,(z-0.5)*diag);
          Inc(c);
        end;
    //all anti-clockwise, starting from low corner
    Faces[0]:=Quad(2,0,1,3); //West
    Faces[1]:=Quad(4,6,7,5); //East
    Faces[2]:=Quad(6,2,3,7); //North
    Faces[3]:=Quad(0,4,5,1); //South
    Faces[4]:=Quad(1,5,7,3); //Top
    Faces[5]:=Quad(0,2,6,4); //Bottom
    end;
end;

function QuadSphere(Splits:Integer):TQuadMesh;

procedure SplitFaces;

var
  newquads:TQuads;
  newpoints:TOCCoords;
  edges,midpoint:array of array [0..3] of Longint;
    //edges are other points to which each old point connects
    //midpoint is -1 or the index of thenew point in the middle
  f,pointix,quadix:Longint;

procedure SortVertices(var P1,P2:Integer);

var ix:Integer;

begin
  if P2<P1 then
    begin
    ix:=P1;
    P1:=P2;
    P2:=ix;
    end;
end;

procedure PlaceEdge(P1,P2:Integer);

var ix:Integer;

begin
  //only place edge in first index
  SortVertices(P1,P2);
  //place P2 as an edge of P1
  ix:=0;
  while (edges[P1,ix]>=0) and (edges[P1,ix]<>P2) do Inc(ix);
  edges[P1,ix]:=P2;
end;

procedure ListEdges;

var f,g:Integer;

begin
  with Result do
  for f:=0 to High(Faces) do
    begin
    PlaceEdge(Faces[f,0],Faces[f,1]);
    PlaceEdge(Faces[f,1],Faces[f,2]);
    PlaceEdge(Faces[f,2],Faces[f,3]);
    PlaceEdge(Faces[f,3],Faces[f,0]);
    end;
end;

procedure Setup;
//sets new arrays and indexing on old edges

var f,g:Integer;

begin
  with Result do
  begin
  quadix:=0;
  SetLength(newquads,Length(Faces)*4);
  SetLength(newpoints,
    Length(Points)+  //old points
    +Length(Faces)+  //one per face, middle
    +2*Length(Faces)); //two edges per face
  SetLength(edges,Length(Points));
  SetLength(midpoint,Length(Points));
  for f:=0 to High(Points) do
    begin
    //first set of newpoints is a copy of the old to keep the same indexes
    newpoints[f]:=Points[f];
    for g:=0 to 3 do
      begin
      edges[f,g]:=-1;
      midpoint[f,g]:=-1;
      end;
    end;
  pointix:=Length(Points);
  end;
  ListEdges;
end;

function AddPoint(X,Y,Z:Single):Integer;
//normalizes, adds and returns the index

var s:Single;

begin
  Result:=pointix;
  s:=1/Sqrt(Sqr(X)+Sqr(Y)+Sqr(Z));
  newpoints[pointix,0]:=X*s;
  newpoints[pointix,1]:=Y*s;
  newpoints[pointix,2]:=Z*s;
  Inc(pointix);
end;

function EdgeMidpoint(P1,P2:Integer):Integer;
//checks if the midpoint has been calculated, returns the index
//creates the midpoint if needed

var f:Integer;

begin
  SortVertices(P1,P2);
  f:=0;
  while edges[P1,f]<>P2 do Inc(f);
  Result:=midpoint[P1,f];
  if Result<0 then
    begin
    Result:=AddPoint(
      0.5*(newpoints[P1,0]+newpoints[P2,0]),
      0.5*(newpoints[P1,1]+newpoints[P2,1]),
      0.5*(newpoints[P1,2]+newpoints[P2,2]));
    midpoint[P1,f]:=Result;
    end;
end;

procedure SplitQuad(Ix:Integer);

var
  qps:array[0..8] of Integer; // index to the new points in the face
  f,p1,p2:Integer;

begin
  //build new points
  //first 4 are the old ones
  for f:=0 to 3 do
    qps[f]:=Result.Faces[Ix,f];
  //Next is midpoint. Note that newpoints already have a copy of the old points here
  qps[4]:=AddPoint(
    0.25*(newpoints[qps[0],0]+newpoints[qps[1],0]+newpoints[qps[2],0]+newpoints[qps[3],0]),
    0.25*(newpoints[qps[0],1]+newpoints[qps[1],1]+newpoints[qps[2],1]+newpoints[qps[3],1]),
    0.25*(newpoints[qps[0],2]+newpoints[qps[1],2]+newpoints[qps[2],2]+newpoints[qps[3],2]));
  //Finally, the edges
  for f:=0 to 3 do
    begin
    p1:=qps[f];
    if f<3 then p2:=qps[f+1]
    else p2:=qps[0];
    qps[f+5]:=EdgeMidpoint(p1,p2);
    end;

  //now the quads
  newquads[quadix]:=Quad(qps[0],qps[5],qps[4],qps[8]); Inc(quadix);
  newquads[quadix]:=Quad(qps[5],qps[1],qps[6],qps[4]); Inc(quadix);
  newquads[quadix]:=Quad(qps[4],qps[6],qps[2],qps[7]); Inc(quadix);
  newquads[quadix]:=Quad(qps[8],qps[4],qps[7],qps[3]); Inc(quadix);
end;

begin
  Setup;
  for f:=0 to High(Result.Faces) do
    SplitQuad(f);
  Result.Faces:=newquads;
  Result.Points:=newpoints;
end;

var f:Integer;

begin
  Result:=QuadCube;
  for f:=1 to Splits do SplitFaces;
end;

function DefaultMaterial:T3DMaterial;
//this sets the defaults on all fields. Other functions should call this one before
//setting their fields (Color, texture, etc)

begin
  with Result do
    begin
    Diffuse:=RGBAColor(0.5,0.5,0.5,1);
    Specular:=Diffuse;
    Ambient:=Diffuse;
    Texture:='';
  end;

end;

function ColorMaterial(R,G,B,A:TOCFloat):T3DMaterial;

begin
  Result:=DefaultMaterial;
  Result.Diffuse:=RGBAColor(R,G,B,A);
  Result.Ambient:=Result.Diffuse;
end;

end.

