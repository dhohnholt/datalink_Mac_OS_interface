import 'package:datalink_core/datalink_core.dart';
import 'package:test/test.dart';
void main() {
 Map<String,Object?> report()=>{
 'exam':{'form':'package','versions':['1','2'],'question_count':1},
 'students':[{'page':1,'student_id':'0012','version':'2','score':{'total':1,'correct':1},'answers':[
 {'question':41,'item':null,'response':'BLANK','correct':false,'confidence':{'needs_review':true}},
 {'question':51,'item':'term','response':'O','correct':true},
 ]}], 'summary':{'student_count':1},'not_scored':[],
 'review_items':[{'page':1,'field':'answer','question':41}],
 };
 test('unused row confidence and review do not block final export',(){expect(reportReadinessProblems(report()),isEmpty);});
 test('scored review blocks final export',(){final r=report();(r['review_items'] as List).add({'page':1,'field':'answer','question':51});expect(reportReadinessProblems(r),isNotEmpty);});
 test('missing versions IDs excluded sheets and totals block export',(){
 final r=report();final s=(r['students'] as List).first;s['version']='';s['student_id']='59_040';s['score']['correct']=0;
 (r['not_scored'] as List).add({'page':22,'reason':'no version bubbled'});
 expect(reportReadinessProblems(r).length,4);
 });
}
