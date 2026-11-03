import 'dart:convert';
import 'package:datalink_core/datalink_core.dart';
import 'package:test/test.dart';
void main(){test('missing roster scores require explicit per-exam absences',(){
 final store=Store.open(':memory:');addTearDown(store.close);
 store.saveClass('P4',[{'id':'1','name':'Present'},{'id':'2','name':'Absent'}]);
 final id=store.createSession('Test','P4',1);
 store.addScan(id,{'number':1,'role':'key','responses':['A']});
 store.addScan(id,{'number':2,'role':'student','student_id':'1','responses':['A']});
 final w=Workspace(store:store,now:()=>DateTime.utc(2026),newId:()=>DateTime.now().microsecondsSinceEpoch.toString());
 expect(()=>w.analysisDownload(id),throwsA(isA<AnalysisError>()));
 w.setStudentAbsent(id,'2',true);
 final r=jsonDecode(w.analysisDownload(id).json);
 expect(r['summary']['student_count'],1);
 expect(r['absent_students'],[{'student_id':'2','student_name':'Absent','reason':'absent'}]);
 expect(()=>w.setStudentAbsent(id,'1',true),throwsA(isA<DataLinkError>()));
 w.setStudentAbsent(id,'2',false);
 expect(()=>w.analysisDownload(id),throwsA(isA<AnalysisError>()));
 w.setStudentAbsent(id,'2',true);
 store.addScan(id,{'number':3,'role':'student','student_id':'2','responses':['A']});
 final makeup=jsonDecode(w.analysisDownload(id).json);
 expect(makeup['summary']['student_count'],2);
 expect(makeup.containsKey('absent_students'),isFalse);
 });}
