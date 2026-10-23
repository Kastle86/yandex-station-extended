package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"sort"
	"strings"
)

// ──────────────────────────────────────────────────────────────────────────
// Музыка без подписки: директива audio_play (общий плеер навыков Алисы).
// Колонка получает client_action "audio_play" с payload'ом google.protobuf.Struct
// {stream{id,url,format,offset_ms}, metadata{title,subtitle}, background_mode, ...}
// и сама качает/играет url через gstreamer. Директива вклеивается в Vins-ответ
// (шаблон s2c_msg0208: 1.2.3 = ответ, его repeated поле 2 = директивы).
// MUSIC_DIR раздаёт файлы по http://<pi>:<ADDR>/music/<name>.
// ──────────────────────────────────────────────────────────────────────────

// ── минимальный protobuf-писатель ──

func pbVarint(b []byte, v uint64) []byte {
	for v >= 0x80 {
		b = append(b, byte(v)|0x80)
		v >>= 7
	}
	return append(b, byte(v))
}

func pbBytes(b []byte, num int, v []byte) []byte {
	b = pbVarint(b, uint64(num)<<3|2)
	b = pbVarint(b, uint64(len(v)))
	return append(b, v...)
}

func pbUint(b []byte, num int, v uint64) []byte {
	return pbVarint(pbVarint(b, uint64(num)<<3), v)
}

// pbValue кодирует google.protobuf.Value из Go-значения.
func pbValue(v any) []byte {
	switch x := v.(type) {
	case nil:
		return pbUint(nil, 1, 0)
	case string:
		return pbBytes(nil, 3, []byte(x))
	case bool:
		n := uint64(0)
		if x {
			n = 1
		}
		return pbUint(nil, 4, n)
	case int:
		return pbDouble(float64(x))
	case float64:
		return pbDouble(x)
	case map[string]any:
		return pbBytes(nil, 5, pbStruct(x))
	case []any:
		var l []byte
		for _, e := range x {
			l = pbBytes(l, 1, pbValue(e))
		}
		return pbBytes(nil, 6, l)
	}
	panic(fmt.Sprintf("pbValue: %T", v))
}

func pbDouble(f float64) []byte {
	b := pbVarint(nil, 2<<3|1)
	return binary.LittleEndian.AppendUint64(b, math.Float64bits(f))
}

// pbStruct кодирует google.protobuf.Struct (ключи сортируем — стабильный вывод).
func pbStruct(m map[string]any) []byte {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b []byte
	for _, k := range keys {
		e := pbBytes(nil, 1, []byte(k))
		e = pbBytes(e, 2, pbValue(m[k]))
		b = pbBytes(b, 1, e)
	}
	return b
}

// pbDirective — client_action в формате Vins-ответа (как tts_play_placeholder в шаблоне).
func pbDirective(name string, payload map[string]any) []byte {
	b := pbBytes(nil, 1, []byte("client_action"))
	b = pbBytes(b, 2, []byte(name))
	b = pbBytes(b, 3, []byte(name))
	b = pbBytes(b, 5, pbStruct(payload))
	return pbUint(b, 8, 1)
}

// pbAppendAt дописывает поле field (wire2) во вложенное сообщение по пути path,
// пересобирая длины всех родителей. Остальные поля копируются байт-в-байт.
func pbAppendAt(msg []byte, path []int, field int, val []byte) ([]byte, bool) {
	return pbEditAt(msg, path, func(body []byte) []byte {
		return pbBytes(append([]byte{}, body...), field, val)
	})
}

// pbEditAt заменяет вложенное сообщение по пути path на fn(старое тело).
func pbEditAt(msg []byte, path []int, fn func([]byte) []byte) ([]byte, bool) {
	if len(path) == 0 {
		return fn(msg), true
	}
	var out []byte
	done := false
	i := 0
	for i < len(msg) {
		start := i
		tag, ni, ok := pbReadVarint(msg, i)
		if !ok {
			return nil, false
		}
		i = ni
		f, w := int(tag>>3), int(tag&7)
		switch w {
		case 0:
			if _, i, ok = pbReadVarint(msg, i); !ok {
				return nil, false
			}
		case 1:
			i += 8
		case 5:
			i += 4
		case 2:
			l, ni2, ok := pbReadVarint(msg, i)
			if !ok || ni2+int(l) > len(msg) {
				return nil, false
			}
			body := msg[ni2 : ni2+int(l)]
			i = ni2 + int(l)
			if f == path[0] && !done {
				nb, ok := pbEditAt(body, path[1:], fn)
				if !ok {
					return nil, false
				}
				out = pbBytes(out, f, nb)
				done = true
				continue
			}
		default:
			return nil, false
		}
		if i > len(msg) {
			return nil, false
		}
		out = append(out, msg[start:i]...)
	}
	return out, done
}

func newGUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// audioPlayDirective — директива проиграть url общим плеером колонки.
// url/title (и очередь q/i) кладём в scenario_meta: колонка возвращает его в
// device_state при player_continue/next/prev, так что серверу не нужно состояние.
func audioPlayDirective(streamID, url, title, subtitle string, offsetMs int, meta ...map[string]any) []byte {
	sm := map[string]any{"url": url, "title": title}
	for _, m := range meta {
		for k, v := range m {
			sm[k] = v
		}
	}
	cb := map[string]any{}
	if os.Getenv("MUSIC_CALLBACKS") != "" {
		// конец/ошибка трека -> колонка шлёт server_action с этим именем -> следующий
		next := map[string]any{"name": musicNextCallback, "payload": map[string]any{},
			"ignore_answer": false, "is_led_silent": true}
		cb = map[string]any{"on_finished": next, "on_failed": next}
	}
	return pbDirective("audio_play", map[string]any{
		"stream": map[string]any{
			"id":        streamID,
			"url":       url,
			"format":    "MP3",
			"offset_ms": offsetMs,
		},
		"metadata": map[string]any{
			"title":    title,
			"subtitle": subtitle,
		},
		"background_mode": "Ducking",
		"screen_type":     "Default",
		"provider_name":   "",
		"set_pause":       false,
		"callbacks":       cb,
		"scenario_meta":   sm,
	})
}

const musicNextCallback = "alice_music_next"

// queueDirective — audio_play на поток очереди, начиная с трека idx (+offsetMs внутри).
func queueDirective(q *qStream, idx int, offsetMs int) []byte {
	sng := q.Songs[idx]
	log.Printf("MUSIC play q/%s [%d/%d] %s (%s)", q.ID, idx+1, len(q.Songs), sng.name(), sng.Album)
	return audioPlayDirective(newGUID(), q.url(), sng.name(), sng.Album, q.startMs(idx)+offsetMs,
		map[string]any{"qid": q.ID})
}

// playSongs — очередь из списка (до max) одним потоком; короткая очередь
// добивается похожими на последний трек, чтобы музыка не обрывалась.
func playSongs(songs []ndSong, max int) []byte {
	if len(songs) == 0 {
		return nil
	}
	if len(songs) < 30 {
		if sim, err := similarSongs(songs[len(songs)-1].ID, 40); err == nil {
			songs = append(songs, sim...)
		}
	}
	if len(songs) > max {
		songs = songs[:max]
	}
	q, err := newQStream(songs)
	if err != nil {
		log.Printf("MUSIC queue: %v", err)
		return nil
	}
	return queueDirective(q, 0, 0)
}

// current — очередь и номер играющего трека по device_state.
func current(st playerState) (*qStream, int) {
	q := getQStream(st.qid)
	if q == nil {
		return nil, 0
	}
	return q, q.trackAt(st.offsetMs)
}

// stepQueue — соседний трек (delta=+1/-1). За концом очереди — радио:
// новая очередь из похожих на последний трек.
func stepQueue(st playerState, delta int) ([]byte, string) {
	q, cur := current(st)
	if q == nil {
		return nil, "нет очереди"
	}
	idx := max(cur+delta, 0)
	if idx >= len(q.Songs) && q.Songs[0].Book != "" {
		return nil, "книга кончилась"
	}
	if idx >= len(q.Songs) {
		sim, err := similarSongs(q.Songs[len(q.Songs)-1].ID, 40)
		if err != nil || len(sim) == 0 {
			return nil, fmt.Sprintf("очередь кончилась, похожих нет (%v)", err)
		}
		return playSongs(sim, 100), "радио: " + sim[0].name()
	}
	return queueDirective(q, idx, 0), fmt.Sprintf("%d/%d %s", idx+1, len(q.Songs), q.Songs[idx].name())
}

// resumeDirective — продолжить с позиции колонки (тот же поток, тот же offset).
func resumeDirective(st playerState) []byte {
	title := st.title
	if q, cur := current(st); q != nil {
		title = q.Songs[cur].name()
	}
	return audioPlayDirective(st.streamID, st.url, title, "", st.offsetMs, map[string]any{"qid": st.qid})
}

// nowPlaying — название играющего трека по позиции в потоке.
func nowPlaying(st playerState) string {
	if q, cur := current(st); q != nil {
		return q.Songs[cur].name()
	}
	return st.title
}

// pbPath спускается по цепочке вложенных сообщений (первое вхождение каждого поля).
func pbPath(b []byte, path ...int) ([]byte, bool) {
	for _, n := range path {
		v, _, w, ok := pbField(b, n)
		if !ok || w != 2 {
			return nil, false
		}
		b = v
	}
	return b, true
}

// pbEach вызывает fn для каждого вхождения поля num (wire2).
func pbEach(b []byte, num int, fn func([]byte)) {
	for i := 0; i < len(b); {
		tag, ni, ok := pbReadVarint(b, i)
		if !ok {
			return
		}
		i = ni
		switch tag & 7 {
		case 0:
			if _, i, ok = pbReadVarint(b, i); !ok {
				return
			}
		case 1:
			i += 8
		case 5:
			i += 4
		case 2:
			l, ni2, ok := pbReadVarint(b, i)
			if !ok || ni2+int(l) > len(b) {
				return
			}
			if int(tag>>3) == num {
				fn(b[ni2 : ni2+int(l)])
			}
			i = ni2 + int(l)
		default:
			return
		}
	}
}

// pbDrop возвращает сообщение без всех вхождений поля num.
func pbDrop(b []byte, num int) []byte {
	var out []byte
	for i := 0; i < len(b); {
		start := i
		tag, ni, ok := pbReadVarint(b, i)
		if !ok {
			return b
		}
		i = ni
		switch tag & 7 {
		case 0:
			if _, i, ok = pbReadVarint(b, i); !ok {
				return b
			}
		case 1:
			i += 8
		case 5:
			i += 4
		case 2:
			l, ni2, ok := pbReadVarint(b, i)
			if !ok {
				return b
			}
			i = ni2 + int(l)
		default:
			return b
		}
		if i > len(b) {
			return b
		}
		if int(tag>>3) != num {
			out = append(out, b[start:i]...)
		}
	}
	return out
}

// semanticFrame — имя фрейма тихого запроса колонки (@@mm_semantic_frame), напр.
// "player_continue" по кнопке play. Путь снят с дампа c2s: 1.2.3.1.24.2.3.
func semanticFrame(pb []byte) string {
	if !bytes.Contains(pb, []byte("@@mm_semantic_frame")) {
		return ""
	}
	b, ok := pbPath(pb, 1, 2, 3, 1, 24, 2)
	if !ok {
		return ""
	}
	v, _, _, _ := pbField(b, 3)
	return string(v)
}

// playerState — что играло по device_state.audio_player (тихий запрос 1.2.3.18.22,
// голосовой 1.3.3.18.22): 1=state, 2=offset_ms, 3.1=stream id, 3.3=title,
// 4=scenario_meta (наши url/title/q/i).
type playerState struct {
	streamID, url, title, qid string
	offsetMs                  int
}

func audioPlayerState(pb []byte) (st playerState, ok bool) {
	ap, ok := pbPath(pb, 1, 2, 3, 18, 22)
	if !ok {
		if ap, ok = pbPath(pb, 1, 3, 3, 18, 22); !ok {
			return st, false
		}
	}
	if _, v, _, o := pbField(ap, 2); o {
		st.offsetMs = int(v)
	}
	if item, o := pbPath(ap, 3); o {
		id, _, _, _ := pbField(item, 1)
		t, _, _, _ := pbField(item, 3)
		st.streamID, st.title = string(id), string(t)
	}
	pbEach(ap, 4, func(e []byte) {
		k, _, _, _ := pbField(e, 1)
		v, _, _, _ := pbField(e, 2)
		switch string(k) {
		case "url":
			st.url = string(v)
		case "qid":
			st.qid = string(v)
		}
	})
	return st, st.url != ""
}

// callbackName — имя server_action тихого запроса (1.2.3.1.9), напр. наш
// alice_music_next из callbacks.on_finished.
func callbackName(pb []byte) string {
	ev, ok := pbPath(pb, 1, 2, 3, 1)
	if !ok {
		return ""
	}
	v, _, _, _ := pbField(ev, 9)
	return string(v)
}

// silentResponse — Vins-ответ на тихий запрос (без TTS): шаблон s2c_msg0208 с
// 1.2.3 = только переданные директивы (без tts_play_placeholder/карточки/саджестов).
func silentResponse(msgID, eventID string, directives ...[]byte) ([]byte, error) {
	pb, err := os.ReadFile("wsdump/tpl2/s2c_msg0208.pb")
	if err != nil {
		return nil, err
	}
	out, ok := pbEditAt(pb, []int{1, 2, 3}, func([]byte) []byte {
		var b []byte
		for _, d := range directives {
			b = pbBytes(b, 2, d)
		}
		return b
	})
	if !ok {
		return nil, fmt.Errorf("шаблон без 1.2.3")
	}
	// 1.2.2 = текст ответа + 9:1 (переслушать после ответа) — тихому запросу не нужно
	out, _ = pbEditAt(out, []int{1, 2}, func(b []byte) []byte { return pbDrop(b, 2) })
	out = bytes.ReplaceAll(out, capturedMsgID, []byte(msgID))
	return bytes.ReplaceAll(out, capturedEventID, []byte(eventID)), nil
}

// handleSemanticFrame отвечает на тихие запросы плеера. true = обработали.
func handleSemanticFrame(ws *wsConn, id uint64, pb []byte, msgID, eventID string) bool {
	frame := semanticFrame(pb)
	if frame == "" {
		if callbackName(pb) != musicNextCallback {
			return false
		}
		frame = musicNextCallback // трек доиграл (callbacks.on_finished/on_failed)
	}
	var dirs [][]byte
	st, hasState := audioPlayerState(pb)
	if hasState {
		go saveBookProgress(st)
	}
	switch frame {
	case "player_continue":
		if hasState {
			dirs = append(dirs, resumeDirective(st))
			log.Printf("FAKE id=%d FRAME %s -> audio_play %s @%dms", id, frame, st.url, st.offsetMs)
		} else {
			log.Printf("FAKE id=%d FRAME %s: в device_state нет нашего трека", id, frame)
		}
	case "player_next_track", "player_prev_track", musicNextCallback:
		delta := 1
		if frame == "player_prev_track" {
			delta = -1
		}
		if !hasState {
			log.Printf("FAKE id=%d FRAME %s: в device_state нет нашего трека", id, frame)
			break
		}
		d, what := stepQueue(st, delta)
		if d != nil {
			dirs = append(dirs, d)
		}
		log.Printf("FAKE id=%d FRAME %s -> %s", id, frame, what)
	default:
		// пустой ответ — чтобы колонка не висела 15с на Vins timeout
		log.Printf("FAKE id=%d FRAME %s -> пустой ответ", id, frame)
	}
	resp, err := silentResponse(msgID, eventID, dirs...)
	if err != nil {
		log.Printf("FAKE id=%d FRAME %s: %v", id, frame, err)
		return true
	}
	err = ws.sendAAPI(resp)
	log.Printf("FAKE id=%d FRAME %s response sent (%dB) err=%v", id, frame, len(resp), err)
	return true
}

// musicHandler раздаёт MUSIC_DIR (Range/Content-Length — через http.ServeFile).
func musicHandler() http.Handler {
	dir := os.Getenv("MUSIC_DIR")
	if dir == "" {
		dir = "music"
	}
	files := http.StripPrefix("/music/", http.FileServer(http.Dir(dir)))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/music/q/") {
			serveQ(w, r) // очередь одним потоком
			return
		}
		if strings.HasPrefix(r.URL.Path, "/music/nd/") {
			serveND(w, r) // треки Navidrome (перекодирование в mp3 + Range)
			return
		}
		files.ServeHTTP(w, r)
	})
}
