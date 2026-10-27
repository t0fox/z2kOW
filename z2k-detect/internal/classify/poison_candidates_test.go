package classify

import "testing"

func TestPoisonCandidatesKeepsComposedJointCandidate(t *testing.T) {
	candidate := poison{name: "собрано: fake-seq", gapMS: 123, seqovl: 37}
	got := poisonCandidates(Options{onlyPoison: &candidate})
	if len(got) != 1 {
		t.Fatalf("ожидался один кандидат, получено %d", len(got))
	}
	if got[0].name != candidate.name || got[0].gapMS != candidate.gapMS || got[0].seqovl != candidate.seqovl {
		t.Fatalf("кандидат изменился при повторной проверке: %+v", got[0])
	}
}
