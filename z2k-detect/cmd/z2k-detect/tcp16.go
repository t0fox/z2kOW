package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/necronicle/z2k/z2k-detect/internal/tcp16"
)

// КОДЫ ВЫХОДА tcp16 — контракт со скриптом пробы (files/z2k-tcp16-probe.sh).
//
// Раньше фатальная ошибка выходила с 1, и проба читала это как «блок есть»:
// файл мишеней из одних комментариев давал flag=1 и пересборку конфига
// (ревью 25.10.2026). Теперь у каждого исхода свой код, и «не мерили» никогда
// не совпадает с ответом.
const (
	exitNoBlock  = 0 // проба линии: блока нет; подбор: карта записана, имена есть
	exitBlock    = 1 // проба линии: блок есть
	exitNoNames  = 2 // подбор: карта записана, но имён нет / искать нечего
	exitNoAnswer = 3 // мишени не ответили вовсе — судить не по чему
	exitFatal    = 4 // ошибка входных данных или записи — не мерили
	exitCanceled = 5 // прервано сигналом — результат не засчитан, файлы не тронуты
)

func tcp16Fatal(format string, a ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", a...)
	os.Exit(exitFatal)
}

// exitIfCanceled — прерванный прогон не выносит вердикт и ничего не пишет.
//
// signal.NotifyContext в main отменяет ctx по SIGTERM/SIGINT, и прежде
// probeLine подводил итог по частичным результатам — мог выйти с 0 («блока
// нет») и выключить людям механизм, а подбор писал неполную карту с кодом 0.
func exitIfCanceled(ctx context.Context) {
	if ctx.Err() != nil {
		fmt.Fprintln(os.Stderr, "прервано — результат не засчитан, файлы не тронуты")
		os.Exit(exitCanceled)
	}
}

// writeAtomic пишет файл целиком или не пишет вовсе: временный рядом и
// rename. Боевые файлы читает рантайм, и половина файла для него хуже
// прежнего целого.
func writeAtomic(path string, data []byte) error {
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// tcp16Cmd — проба на блокировку по объёму соединения.
//
// Два режима, и это принципиально разные вопросы:
//
//	без -scan   есть ли этот блок на линии (и в каких AS);
//	с  -scan    какое имя из белого списка провайдер пропускает.
//
// Оба идут по КУРИРУЕМЫМ мишеням, а не по трафику человека: наблюдение за
// чужим потоком отвечает на вопрос «этот хост сейчас режут?» и ошибается, а
// проба спрашивает про линию и мерит контролируемым объёмом.
func tcp16Cmd(ctx context.Context, rest []string) {
	fs := flag.NewFlagSet("tcp16", flag.ExitOnError)
	targets := fs.String("targets", "/opt/zapret2/lists/tcp16_targets.txt", "файл мишеней")
	asn := fs.String("asn", "", "только эта AS (иначе все)")
	confirmed := fs.Bool("confirmed", false, "только AS, подтверждённые многими сообщениями")
	limit := fs.Int("limit", 0, "не больше N мишеней (0 — все)")
	scan := fs.String("scan", "", "файл имён-кандидатов: искать проходящее имя")
	sni := fs.String("sni", "", "проверить одно конкретное имя (иначе — имя мишени из файла)")
	par := fs.Int("parallel", 4, "сколько проб разом")
	asnOut := fs.String("asn-out", "", "куда выписать AS, где блок найден (по одной в строке)")
	noConfirm := fs.Bool("no-confirm", false, "не перепроверять обрыв длинным ожиданием")
	first := fs.Bool("first", true, "при -scan остановиться на первом подошедшем имени")
	perASN := fs.Bool("per-asn", false, "искать своё имя для КАЖДОЙ сети с блоком")
	asnIn := fs.String("asn-in", "", "при -per-asn: подбирать только для AS из этого файла (список пробы линии)")
	prev := fs.String("prev", "", "при -per-asn: прежняя карта — переносить имена, где перемер блока не увидел")
	asnKeep := fs.String("asn-keep", "", "при -per-asn: прежние имена переносить только для AS из этого файла (по умолчанию — -asn-in)")
	batch := fs.Int("batch", 5, "сколько имён проверять разом внутри одной сети")
	sniOut := fs.String("sni-out", "", "куда выписать карту «сеть -> имя»")
	_ = fs.Parse(rest)

	tg, err := loadTargets(*targets, *asn, *confirmed, *limit)
	if err != nil {
		tcp16Fatal("%v", err)
	}
	if len(tg) == 0 {
		tcp16Fatal("мишеней не осталось после фильтров")
	}

	if *scan != "" {
		names, err := loadNames(*scan)
		if err != nil {
			tcp16Fatal("%v", err)
		}
		if len(names) == 0 {
			tcp16Fatal("в %s нет ни одного имени", *scan)
		}
		if *perASN {
			var only map[string]bool
			if *asnIn != "" {
				only, err = loadASNSet(*asnIn)
				if err != nil {
					tcp16Fatal("%v", err)
				}
			}
			keep := only
			if *asnKeep != "" {
				keep, err = loadASNSet(*asnKeep)
				if err != nil {
					tcp16Fatal("%v", err)
				}
			}
			var prevMap map[string]string
			if *prev != "" {
				prevMap = loadSNIMap(*prev)
			}
			scanPerASN(ctx, tg, names, *par, *batch, *sniOut, only, keep, prevMap)
		} else {
			scanNames(ctx, tg, names, *par, *first)
		}
		return
	}
	probeLine(ctx, tg, *sni, *par, *asnOut, !*noConfirm)
}

// targetSNI — имя, с которым идти к мишени: заданное явно, иначе своё.
//
// Прежде проба линии шла ко ВСЕМ мишеням без имени, хотя у части из них оно
// записано в файле: такие без имени отвечают чужой заглушкой, обрыв на них не
// наступает никогда, и их AS не попадала в список сетей с блоком ни при каком
// раскладе (у AS54113 все семь мишеней такие — ревью 25.10.2026).
func targetSNI(t tcp16.Target, sni string) string {
	if sni != "" {
		return sni
	}
	return t.SNI
}

// probeLine отвечает на вопрос «есть ли блок на линии» по каждой AS отдельно.
func probeLine(ctx context.Context, tg []tcp16.Target, sni string, par int, asnOut string, confirm bool) {
	res := runAll(ctx, tg, sni, par)
	exitIfCanceled(ctx)
	if confirm {
		confirmDetected(ctx, res, sni, par)
		exitIfCanceled(ctx)
	}

	type agg struct{ detected, alive, total int }
	byASN := map[string]*agg{}
	for _, r := range res {
		a := byASN[r.Target.ASN]
		if a == nil {
			a = &agg{}
			byASN[r.Target.ASN] = a
		}
		a.total++
		if r.Alive {
			a.alive++
		}
		if r.Detected {
			a.detected++
		}
	}
	keys := make([]string, 0, len(byASN))
	for k := range byASN {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	// Сети, где ни одна мишень не ответила, — не «чисто», а «не мерили».
	// Если такая сеть была в прежнем списке, переносим её: иначе кратковременная
	// недоступность одного хостинга выкидывала его из списка на сутки, и имя
	// для него переставало ставиться (ревью 25.10.2026).
	var prevASN map[string]bool
	if asnOut != "" {
		prevASN, _ = loadASNSet(asnOut)
	}

	// Список AS с блоком нужен рантайму: имя из белого списка ставится только
	// тем адресам, что принадлежат этим AS. Без него мы ставим его всему пулу
	// подряд — замер 30.08.2026: linode, cdn77, aws и scaleway доезжают целиком
	// и без имени, то есть платят за него зря.
	var listASN []string

	anyDetected, anyAlive := 0, 0
	for _, k := range keys {
		a := byASN[k]
		mark := "—"
		switch {
		case a.detected > 0:
			listASN = append(listASN, k)
			mark = "БЛОК"
		case a.alive > 0:
			mark = "чисто"
		case prevASN[k]:
			listASN = append(listASN, k)
			mark = "нет ответа, оставлена из прежнего списка"
		}
		anyDetected += a.detected
		anyAlive += a.alive
		fmt.Printf("AS%-8s %-6s  мишеней %2d, ответили %2d, блок на %d\n", k, mark, a.total, a.alive, a.detected)
	}

	fmt.Println()
	if anyAlive == 0 {
		// Список сетей не трогаем: пустой файл после обрыва связи выключал бы
		// обход у следующего перезапуска движка.
		fmt.Println("ВЕРДИКТ: мишени не отвечают вовсе — линия или список мишеней негодны, судить не по чему")
		os.Exit(exitNoAnswer)
	}
	if asnOut != "" {
		var sb strings.Builder
		sb.WriteString("# AS, где проба нашла блок по объёму. Пересобирается пробой.\n")
		for _, k := range listASN {
			sb.WriteString(k)
			sb.WriteString("\n")
		}
		if err := writeAtomic(asnOut, []byte(sb.String())); err != nil {
			tcp16Fatal("не смог записать %s: %v", asnOut, err)
		}
	}
	if anyDetected > 0 {
		fmt.Printf("ВЕРДИКТ: блок по объёму ЕСТЬ (сработал на %d мишенях из %d ответивших)\n", anyDetected, anyAlive)
		os.Exit(exitBlock)
	}
	fmt.Printf("ВЕРДИКТ: блока по объёму НЕТ (%d мишеней ответили, ни одна не оборвалась)\n", anyAlive)
	os.Exit(exitNoBlock)
}

// confirmDetected перепроверяет каждый обрыв одной пробой с длинным
// ожиданием. Блоком остаётся только то, что оборвалось оба раза: медленный
// сервер за шесть секунд успевает ответить, замороженное соединение — нет.
func confirmDetected(ctx context.Context, res []tcp16.Result, sni string, par int) {
	if par < 1 {
		par = 1
	}
	sem := make(chan struct{}, par)
	var wg sync.WaitGroup
	for i := range res {
		if !res[i].Detected {
			continue
		}
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			c, cancel := context.WithTimeout(ctx, 60*time.Second)
			defer cancel()
			r := tcp16.ProbeOpt(c, res[i].Target, targetSNI(res[i].Target, sni), tcp16.Opts{MinReadTimeout: tcp16.ConfirmReadTimeout})
			if ctx.Err() != nil {
				return
			}
			if !r.Detected {
				res[i].Detected = false
				res[i].Err = "обрыв не подтвердился при длинном ожидании (медленный сервер)"
			}
		}(i)
	}
	wg.Wait()
}

// scanPerASN ищет СВОЁ имя для КАЖДОЙ сети, где нашёлся блок.
//
// Одного имени на всех не бывает — замер 30.08.2026 на линии владельца:
// hcaptcha.com бьёт двадцать AS, но НЕ Hetzner; Hetzner, DigitalOcean и OVH
// берёт 300.ya.ru; Melbicom — ad.adriver.ru; семь AS не берёт ничего.
//
// Мишени порта 80 в подборе не участвуют: там нет TLS, имя подставлять некуда,
// и требовать от них «пройти» — значит не найти имя никогда.
//
// only — список сетей с блоком от пробы линии. Прежде подбор брал ВСЕ AS с
// портом 443 и заново искал блок сам: карта получала имена для сетей вне
// списка (рантайм их не применит), а сеть из списка, где повторная проба
// случайно не увидела блок, оставалась без имени (ревью 25.10.2026).
//
// prev — прежняя карта. Имя переносится, когда сеть в этот прогон не
// подбиралась (её нет среди мишеней с портом 443 или подбор шёл по части
// сетей) либо перемер блока на ней не увидел. Имя выбрасывается только тогда,
// когда блок виден, а ни одно имя, включая прежнее, не прошло: оно протухло.
//
// keep — какие сети вообще могут остаться в карте (обычно тот же список
// пробы линии). Отдельно от only нужен второй фазе подбора: она подбирает
// хвост списка только для сетей без имени, а имена, найденные первой фазой,
// обязана перенести все.
func scanPerASN(ctx context.Context, tg []tcp16.Target, names []string, par, sniBatch int, out string, only, keep map[string]bool, prev map[string]string) {
	if sniBatch < 1 {
		sniBatch = 1
	}
	byASN := map[string][]tcp16.Target{}
	for _, t := range tg {
		// Без TLS (порт 80) имя подставлять некуда — то же условие, что в
		// самой пробе (internal/tcp16: TLS на любом порту, кроме 80).
		if t.Port == 80 {
			continue
		}
		if only != nil && !only[t.ASN] {
			continue
		}
		byASN[t.ASN] = append(byASN[t.ASN], t)
	}

	keys := make([]string, 0, len(byASN))
	for k := range byASN {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	type found struct {
		asn, name string
		tried     int
		carried   bool // имя перенесено из прежней карты
		noBlock   bool // перемер блока не увидел
	}
	results := make([]found, len(keys))
	// Общий потолок одновременных проб на весь прогон. Ограничивать только
	// число сетей мало: внутри каждой идёт ещё батч, и суммарная нагрузка
	// получается непредсказуемой. Замер 31.08.2026 на роутере: проба линии по
	// 110 мишеням при потолке 4 шла 2 м 44 с, при 50 — 15 секунд.
	gate := make(chan struct{}, max(par, 1))
	probe := func(t tcp16.Target, sni string, o tcp16.Opts) tcp16.Result {
		gate <- struct{}{}
		defer func() { <-gate }()
		return tcp16.ProbeOpt(ctx, t, sni, o)
	}

	// ИМЕНА, НАЙДЕННЫЕ ДРУГИМИ СЕТЯМИ, — ПЕРВЫМИ.
	//
	// Белый список у коробки один на всех: имя, прошедшее у одной сети, чаще
	// всего проходит и у соседних (замер 25.10.2026 — hcaptcha.com первым
	// подошёл 26 сетям из 34). Сеть, у которой первые кандидаты не прошли,
	// перед очередной пачкой пробует свежие находки соседей, а не ползёт по
	// списку дальше.
	var fmu sync.Mutex
	var foundNames []string
	addFound := func(n string) {
		fmu.Lock()
		defer fmu.Unlock()
		for _, x := range foundNames {
			if x == n {
				return
			}
		}
		foundNames = append(foundNames, n)
	}
	snapshotFound := func() []string {
		fmu.Lock()
		defer fmu.Unlock()
		return append([]string(nil), foundNames...)
	}

	// Печатаем по мере готовности: полный прогон идёт минуты, и молчащий до
	// конца вывод не даёт понять ни что он жив, ни на чём стоит.
	var pmu sync.Mutex
	say := func(f found) {
		pmu.Lock()
		defer pmu.Unlock()
		switch {
		case f.name != "" && f.carried:
			fmt.Printf("AS%-8s ОСТАВЛЕНО %-22s (перемер блока не увидел, имя из прежней карты)\n", f.asn, f.name)
		case f.name != "":
			fmt.Printf("AS%-8s ПОДОШЛО %-24s (кандидат %d)\n", f.asn, f.name, f.tried)
		case f.tried > 0:
			fmt.Printf("AS%-8s имя не найдено (перебрано %d)\n", f.asn, f.tried)
		default:
			fmt.Printf("AS%-8s блока нет — имя не нужно\n", f.asn)
		}
	}
	var wg sync.WaitGroup

	for i, asn := range keys {
		wg.Add(1)
		go func(i int, asn string, tgs []tcp16.Target) {
			defer wg.Done()

			// Мишень выбираем ту, на которой блок реально виден, а из
			// нескольких таких — с наименьшим RTT: перебор идёт по ней сотню
			// раз, и лишние сто миллисекунд на пробу выливаются в минуты.
			// Без проверки «блок виден» «подошло» скажет любое имя.
			var target *tcp16.Target
			var bestRTT time.Duration
			for j := range tgs {
				r := probe(tgs[j], tgs[j].SNI, tcp16.Opts{})
				if r.Alive && r.Detected && (target == nil || r.RTT < bestRTT) {
					target = &tgs[j]
					bestRTT = r.RTT
				}
			}
			// Выбранную мишень перепроверяем длинным ожиданием: медленный
			// сервер, принятый за блок, проваливает все имена, и сеть
			// осталась бы без имени на пустом месте.
			if target != nil {
				r := probe(*target, target.SNI, tcp16.Opts{MinReadTimeout: tcp16.ConfirmReadTimeout})
				if !r.Detected {
					target = nil
				}
			}
			if ctx.Err() != nil {
				return
			}
			if target == nil {
				results[i] = found{asn: asn, noBlock: true}
				if n := prev[asn]; n != "" {
					results[i].name, results[i].carried = n, true
				}
				say(results[i])
				return
			}

			tried := map[string]bool{}
			tryBatch := func(batch []string, base int) (string, int, bool) {
				ok := make([]bool, len(batch))
				var bwg sync.WaitGroup
				for j, name := range batch {
					tried[name] = true
					bwg.Add(1)
					go func(j int, name string) {
						defer bwg.Done()
						ok[j] = probe(*target, name, tcp16.Opts{}).Passed
					}(j, name)
				}
				bwg.Wait()
				if ctx.Err() != nil {
					return "", 0, false
				}
				for j := range batch {
					if ok[j] {
						return batch[j], base + j + 1, true
					}
				}
				return "", 0, false
			}

			// Кандидаты идём БАТЧАМИ. По одному это 188 × шесть секунд на
			// сеть, где не подходит ничто, — двадцать минут вместо четырёх.
			// Батч запускается целиком, из подошедших берём ПЕРВОГО ПО
			// ПОРЯДКУ В ФАЙЛЕ: порядок там осмысленный, и «какой раньше
			// ответил» его бы ломал.
			for start := 0; start < len(names); start += sniBatch {
				if ctx.Err() != nil {
					return
				}
				// Сначала находки соседей, которых эта сеть ещё не пробовала.
				var fresh []string
				for _, n := range snapshotFound() {
					if !tried[n] {
						fresh = append(fresh, n)
					}
				}
				for len(fresh) > 0 {
					end := min(sniBatch, len(fresh))
					if n, _, ok := tryBatch(fresh[:end], 0); ok {
						results[i] = found{asn: asn, name: n, tried: len(tried)}
						say(results[i])
						return
					}
					fresh = fresh[end:]
				}
				end := min(start+sniBatch, len(names))
				var batch []string
				for _, n := range names[start:end] {
					if !tried[n] {
						batch = append(batch, n)
					}
				}
				if len(batch) == 0 {
					continue
				}
				if n, _, ok := tryBatch(batch, start); ok {
					addFound(n)
					results[i] = found{asn: asn, name: n, tried: len(tried)}
					say(results[i])
					return
				}
			}
			results[i] = found{asn: asn, tried: len(tried)}
			say(results[i])
		}(i, asn, byASN[asn])
	}
	wg.Wait()
	exitIfCanceled(ctx)

	// Итоговая карта: найденное в этот прогон плюс перенесённое из прежней
	// для сетей, которые в этот прогон не подбирались (и при списке only —
	// только для сетей из него: имя сети без блока рантайм не применит).
	final := map[string]string{}
	scanned := map[string]bool{}
	for _, r := range results {
		if r.asn == "" {
			continue
		}
		scanned[r.asn] = true
		if r.name != "" {
			final[r.asn] = r.name
		}
	}
	carriedOther := 0
	for a, n := range prev {
		if scanned[a] || n == "" {
			continue
		}
		if keep != nil && !keep[a] {
			continue
		}
		final[a] = n
		carriedOther++
	}
	fkeys := make([]string, 0, len(final))
	for a := range final {
		fkeys = append(fkeys, a)
	}
	sort.Strings(fkeys)

	var sb strings.Builder
	sb.WriteString("# Имя из белого списка на каждую сеть, где найден блок по объёму.\n")
	sb.WriteString("# Формат: <asn><TAB><имя>. Пересобирается пробой.\n")
	foundNow := 0
	for _, r := range results {
		if r.name != "" && !r.carried {
			foundNow++
		}
	}
	for _, a := range fkeys {
		sb.WriteString(a)
		sb.WriteString("\t")
		sb.WriteString(final[a])
		sb.WriteString("\n")
	}
	fmt.Printf("\nимена найдены для %d сетей из %d подобранных; в карте %d (перенесено без подбора: %d)\n",
		foundNow, len(keys), len(final), carriedOther)
	// Карту пишем ВСЕГДА, когда подбор дошёл до конца, даже пустую: так
	// «подбор завершён» отличается от «подбор оборвался» по самому файлу.
	if out != "" {
		if err := writeAtomic(out, []byte(sb.String())); err != nil {
			tcp16Fatal("не смог записать %s: %v", out, err)
		}
	}
	if len(final) == 0 {
		os.Exit(exitNoNames)
	}
}

// scanNames ищет имя, с которым мишень перестаёт обрываться.
func scanNames(ctx context.Context, tg []tcp16.Target, names []string, par int, stopFirst bool) {
	// Сперва убеждаемся, что на этих мишенях блок вообще есть: иначе любое имя
	// «подойдёт», и мы запишем в находки первое попавшееся.
	base := runAll(ctx, tg, "", par)
	exitIfCanceled(ctx)
	blocked := base[:0]
	for _, r := range base {
		if r.Detected {
			blocked = append(blocked, r)
		}
	}
	if len(blocked) == 0 {
		fmt.Println("на этих мишенях блока нет — искать нечего")
		os.Exit(exitNoNames)
	}
	fmt.Printf("мишеней с блоком: %d, кандидатов: %d\n\n", len(blocked), len(names))

	found := 0
	for _, name := range names {
		ok := 0
		for _, b := range blocked {
			if tcp16.Probe(ctx, b.Target, name).Passed {
				ok++
			}
		}
		exitIfCanceled(ctx)
		if ok == len(blocked) {
			fmt.Printf("ПОДОШЛО %s (прошло %d/%d мишеней)\n", name, ok, len(blocked))
			found++
			if stopFirst {
				return
			}
		}
	}
	if found == 0 {
		fmt.Println("ни одно имя из списка не прошло")
		os.Exit(exitNoNames)
	}
}

func runAll(ctx context.Context, tg []tcp16.Target, sni string, par int) []tcp16.Result {
	if par < 1 {
		par = 1
	}
	out := make([]tcp16.Result, len(tg))
	sem := make(chan struct{}, par)
	var wg sync.WaitGroup
	for i, t := range tg {
		wg.Add(1)
		go func(i int, t tcp16.Target) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			c, cancel := context.WithTimeout(ctx, 40*time.Second)
			defer cancel()
			out[i] = tcp16.Probe(c, t, targetSNI(t, sni))
		}(i, t)
	}
	wg.Wait()
	return out
}

func loadTargets(path, asn string, confirmedOnly bool, limit int) ([]tcp16.Target, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("нет файла мишеней %s: %w", path, err)
	}
	defer f.Close()

	var out []tcp16.Target
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		p := strings.Split(line, "\t")
		if len(p) < 6 {
			continue
		}
		if asn != "" && p[1] != asn {
			continue
		}
		if confirmedOnly && p[2] != "*" {
			continue
		}
		port, err := strconv.Atoi(strings.TrimSpace(p[5]))
		if err != nil {
			continue
		}
		t := tcp16.Target{ID: p[0], ASN: p[1], Provider: p[3], IP: p[4], Port: port}
		// Седьмая колонка — имя для SNI, необязательная: файлы прежнего
		// формата читаются как раньше.
		if len(p) >= 7 {
			t.SNI = strings.TrimSpace(p[6])
		}
		out = append(out, t)
		if limit > 0 && len(out) >= limit {
			break
		}
	}
	return out, sc.Err()
}

func loadNames(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("нет файла имён %s: %w", path, err)
	}
	defer f.Close()
	var out []string
	seen := map[string]bool{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		s := sc.Text()
		if i := strings.IndexByte(s, '#'); i >= 0 {
			s = s[:i]
		}
		s = strings.TrimSpace(s)
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out, sc.Err()
}

// loadASNSet читает список AS (по одной в начале строки). Нет файла — пустое
// множество и ошибка: для -asn-in это фатально, для прежнего списка — нет.
func loadASNSet(path string) (map[string]bool, error) {
	f, err := os.Open(filepath.Clean(path))
	if err != nil {
		return map[string]bool{}, fmt.Errorf("нет списка AS %s: %w", path, err)
	}
	defer f.Close()
	out := map[string]bool{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		s := strings.TrimSpace(sc.Text())
		if s == "" || strings.HasPrefix(s, "#") {
			continue
		}
		if i := strings.IndexAny(s, " \t"); i >= 0 {
			s = s[:i]
		}
		if _, err := strconv.Atoi(s); err == nil {
			out[s] = true
		}
	}
	return out, sc.Err()
}

// loadSNIMap читает карту «AS<TAB>имя». Нет файла — пустая карта.
func loadSNIMap(path string) map[string]string {
	out := map[string]string{}
	f, err := os.Open(filepath.Clean(path))
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		p := strings.SplitN(strings.TrimSpace(sc.Text()), "\t", 2)
		if len(p) != 2 || strings.HasPrefix(p[0], "#") {
			continue
		}
		if _, err := strconv.Atoi(p[0]); err != nil {
			continue
		}
		if n := strings.TrimSpace(p[1]); n != "" {
			out[p[0]] = n
		}
	}
	return out
}
