// @ts-nocheck
import React, { useState, useEffect, useRef } from 'react';
import {
  Heart,
  Sparkles,
  Send,
  Lock,
  CheckCircle2,
  RefreshCw,
  Edit3,
  Check,
  X,
  Bell,
  Thermometer,
  Smartphone,
  Columns2,
  RotateCcw,
  ShieldCheck,
  MessageCircleHeart,
  Bookmark,
  Settings,
  Wand2,
  Clock,
  Wifi,
  Battery,
  Signal,
  ChevronRight,
  Gift,
  Coffee,
  Smile,
  CalendarHeart,
  Volume2,
} from 'lucide-react';

const SAIBOT_AVATAR = "data:image/jpeg;base64,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";

// 빠른 선택 태그 및 예시 문장
const QUICK_TAGS = [
  {
    id: 'phone',
    label: '#스마트폰집중',
    sample: '밥 먹는데 계속 폰만 봐서 너무 서운하고 화났어',
  },
  {
    id: 'contact',
    label: '#연락빈도',
    sample: '하루 종일 바쁘다고 연락 한 통도 없어서 나만 기다리는 기분이야',
  },
  {
    id: 'affection',
    label: '#표현부족',
    sample: '요즘 나한테 예쁘다거나 좋아한다는 표현을 너무 안 해줘서 외로워',
  },
  {
    id: 'date',
    label: '#데이트코스',
    sample: '맨날 데이트 코스 나만 짜는 것 같아서 좀 지치고 아쉬워',
  },
  {
    id: 'tone',
    label: '#말투서운함',
    sample: '피곤한 건 알겠는데 방금 말투가 너무 차갑고 퉁명스러워서 상처받았어',
  },
];

// 스마트 키워드 매칭 기반 AI 넛지 변환 데이터베이스
const NUDGE_LIBRARY = {
  phone: {
    category: '오늘의 커플 추천 팁',
    tagName: '스마트폰 집중',
    empathy:
      '함께 있는 소중한 시간인데 나보다 화면을 더 오래 보는 것 같으면 당연히 마음이 헛헛하고 속상하죠. 그 서운함, 제가 조용히 안아드릴게요. 상대방이 전혀 눈치채지 못하게 오늘 밤 눈 맞추는 시간을 자연스럽게 만들어 볼까요?',
    drafts: [
      {
        title: '디지털 디톡스 15분 챌린지',
        message:
          "오늘 밤 두 분만의 '디지털 디톡스 15분' 어때요? 폰은 잠시 뒤집어 두고, 서로 눈 맞추며 오늘 가장 웃겼던 일 하나씩만 이야기해 보세요!",
        badge: '오늘의 데일리 미션',
        icon: 'coffee',
      },
      {
        title: '식사 시간 눈맞춤 타임',
        message:
          '다음에 같이 밥 먹을 땐 두 분 다 폰을 가방 속에 쏙 넣어두고, 서로의 표정을 보며 천천히 대화해 보는 건 어떨까요? 평소보다 훨씬 다정한 시간이 될 거예요.',
        badge: '커플 추천 팁',
        icon: 'heart',
      },
      {
        title: '잠들기 전 10분 오롯이 우리 둘',
        message:
          '오늘 밤엔 알림을 잠시 무음으로 두고, 두 분만의 이야기에 집중하는 10분을 선물해 보세요. 작은 집중이 큰 안정감을 만들어 줘요.',
        badge: '오늘의 데일리 미션',
        icon: 'sparkles',
      },
    ],
  },
  contact: {
    category: '다정함 리마인더',
    tagName: '연락 빈도',
    empathy:
      '기다리는 시간은 실제보다 훨씬 길게 느껴지잖아요. 바쁠 거라 이해하려 해도 막상 연락이 뜸하면 마음이 작아질 수밖에 없어요. 부담 주지 않으면서도 반가운 연락이 먼저 오도록 살짝 신호를 띄워볼게요.',
    drafts: [
      {
        title: '하늘 사진 한 장 & 짧은 안부',
        message:
          '바쁜 하루 중 딱 10초! 지금 보이는 풍경이나 마시는 커피 사진 한 장과 함께 "지금 문득 네 생각났어"라고 먼저 톡 보내보는 건 어때요?',
        badge: '오늘의 데일리 미션',
        icon: 'sparkles',
      },
      {
        title: '퇴근 전 1분 목소리 선물',
        message:
          '메시지 대신 오늘 저녁엔 짧은 음성 메시지나 1분 통화로 "오늘 하루 어땠어?" 하고 다정하게 안부를 물어봐 주세요!',
        badge: '커플 추천 팁',
        icon: 'heart',
      },
      {
        title: '이동 중 소소한 일상 중계',
        message:
          '거창한 이야기가 아니어도 괜찮아요. 지금 뭐 하고 있는지 한 줄만 슬쩍 공유해 주면, 연인의 하루가 훨씬 든든해질 거예요.',
        badge: '다정함 리마인더',
        icon: 'coffee',
      },
    ],
  },
  affection: {
    category: '오늘의 커플 추천 팁',
    tagName: '표현 부족',
    empathy:
      '마음이야 알지만 가끔은 말과 행동으로 확인받고 싶을 때가 있잖아요. 표현이 줄어들면 괜히 혼자 서운해지기도 하고요. 상대방이 오늘 자연스럽게 애정을 듬뿍 표현할 수 있는 따뜻한 미션을 보내볼게요.',
    drafts: [
      {
        title: '오늘의 진심 한 문장 전하기',
        message:
          '익숙함에 잠시 아껴두었던 말, 오늘은 꼭 꺼내볼까요? 상대방의 좋은 점 한 가지를 콕 집어 "난 너의 이런 점이 참 좋아"라고 말해 주세요!',
        badge: '오늘의 데일리 미션',
        icon: 'heart',
      },
      {
        title: '말없이 5초 꼭 안아주기',
        message:
          '오늘 만나면 아무 말 없이 5초만 꽉 안아주는 건 어때요? 백 마디 말보다 따뜻한 포옹 한 번이 마음을 가장 빠르게 채워준대요.',
        badge: '커플 추천 팁',
        icon: 'sparkles',
      },
      {
        title: '갑작스러운 칭찬 폭격 미션',
        message:
          '오늘 연인의 스타일이나 작은 배려 중 눈에 띄는 한 가지를 찾아 진심 담아 칭찬해 보세요. 환하게 웃는 얼굴을 볼 수 있을 거예요!',
        badge: '다정함 리마인더',
        icon: 'gift',
      },
    ],
  },
  date: {
    category: '데이트 영감 카드',
    tagName: '데이트 코스',
    empathy:
      '매번 먼저 고민하고 준비하다 보면 "나만 애쓰나?" 하는 마음이 들기 마련이에요. 고생 많으셨어요. 이번엔 상대방이 설레는 마음으로 먼저 데이트 아이디어를 꺼낼 수 있게 슬쩍 영감을 불어넣어 줄게요!',
    drafts: [
      {
        title: '이번 주말 비밀 코스 제안하기',
        message:
          '이번 데이트는 내가 먼저 깜짝 제안 어때요? 가보고 싶었던 맛집이나 예쁜 카페 2곳을 골라 "우리 여기 갈까?" 하고 먼저 물어봐 주세요!',
        badge: '데이트 추천 미션',
        icon: 'calendar',
      },
      {
        title: '우리만의 소확행 산책 루트',
        message:
          '거창한 계획이 아니어도 좋아요. 이번 주엔 연인과 함께 걷고 싶은 동네나 디저트 가게를 하나 정해서 먼저 데이트 신청을 해보세요!',
        badge: '커플 추천 팁',
        icon: 'coffee',
      },
      {
        title: '다음 데이트 버킷리스트 1개 고르기',
        message:
          '요즘 핫한 전시회나 야경 명소 중 연인이 좋아할 만한 곳 하나를 슬쩍 찾아 링크를 보내보세요. 준비하는 마음 자체가 큰 선물이 돼요.',
        badge: '오늘의 데일리 미션',
        icon: 'sparkles',
      },
    ],
  },
  tone: {
    category: '다정한 대화 팁',
    tagName: '말투 서운함',
    empathy:
      '가까운 사이라서 더 쉽게 상처받는 게 말투인 것 같아요. 본심은 그게 아니란 걸 알아도 차갑게 들리면 마음이 콕 찔리잖아요. 상대방이 오늘 부드러운 온도로 먼저 말을 걸어올 수 있게 다정한 대화 넛지를 준비했어요.',
    drafts: [
      {
        title: '다정한 말끝 쿠션 미션',
        message:
          '피곤한 날일수록 말끝에 다정함을 한 스푼 더해보는 건 어때요? 오늘 대화할 땐 "고마워", "그랬구나~" 같은 따뜻한 리액션을 한 번 더 건네보세요.',
        badge: '오늘의 데일리 미션',
        icon: 'smile',
      },
      {
        title: '오늘 고마웠던 일 하나 말하기',
        message:
          '잠시 숨을 고르고 연인에게 "오늘 네 덕분에 힘이 났어" 혹은 "항상 내 편 되어줘서 고마워" 하고 부드럽게 먼저 말을 걸어보는 건 어떨까요?',
        badge: '커플 추천 팁',
        icon: 'heart',
      },
      {
        title: '웃음으로 분위기 녹이기',
        message:
          '가끔은 짧은 이모티콘 하나와 부드러운 인사만으로도 하루의 긴장이 스르르 풀려요. 지금 따뜻한 톤으로 다정한 안부 한마디 건네보세요!',
        badge: '다정함 리마인더',
        icon: 'sparkles',
      },
    ],
  },
  default: {
    category: '오늘의 커플 추천 팁',
    tagName: '마음 돌보기',
    empathy:
      '말로 꺼내기 쉽지 않은 속마음을 솔직하게 들려줘서 고마워요. 서운한 감정은 꾹 눌러두기보다 이렇게 풀어내는 것만으로도 한결 가벼워져요. 상대방이 오늘 유난히 다정하게 다가올 수 있도록 자연스러운 미션을 만들어 드릴게요.',
    drafts: [
      {
        title: '오늘의 다정함 10분 티타임',
        message:
          '오늘 저녁엔 따뜻한 음료 한 잔과 함께 "요즘 혹시 힘든 일 없어?" 하고 연인의 마음을 먼저 토닥여 주는 10분을 가져보는 건 어때요?',
        badge: '오늘의 데일리 미션',
        icon: 'coffee',
      },
      {
        title: '작은 배려 한 가지 먼저 챙기기',
        message:
          '거창한 이벤트보다 작은 관심 하나가 마음을 녹여요. 오늘 연인이 평소 좋아하던 걸 기억해 작은 호의를 먼저 베풀어 보세요!',
        badge: '커플 추천 팁',
        icon: 'gift',
      },
      {
        title: '서로의 하루를 안아주는 한마디',
        message:
          '오늘 하루가 끝나기 전에 "오늘도 수고 많았어, 네가 있어 참 다행이야"라는 말로 따뜻한 마무리를 선물해 보세요.',
        badge: '다정함 리마인더',
        icon: 'heart',
      },
    ],
  },
};

// 평상시에도 B의 피드에 자연스럽게 섞여 있는 기본 데일리 팁 샘플
const INITIAL_PARTNER_MISSIONS = [
  {
    id: 'organic-1',
    title: '퇴근길 깜짝 간식 서프라이즈',
    message:
      '오늘 퇴근길에 상대방이 좋아하는 간식 하나 사 가는 건 어때요? 작은 서프라이즈가 하루의 피로를 사르르 녹여줄 거예요.',
    badge: '오늘의 커플 추천 팁',
    time: '오전 9:30',
    icon: 'gift',
    accepted: false,
    bookmarked: false,
    fromNudge: false,
  },
  {
    id: 'organic-2',
    title: '추억 사진 한 장 꺼내보기',
    message:
      '함께 찍었던 사진 중 제일 마음에 드는 한 장을 골라 "이때 진짜 좋았지!" 하고 슬쩍 보내보세요. 미소가 절로 번질 거예요.',
    badge: '데일리 미션 카드',
    time: '어제 오후 7:15',
    icon: 'sparkles',
    accepted: true,
    acceptedAt: '어제 완료',
    bookmarked: false,
    fromNudge: false,
  },
  {
    id: 'organic-3',
    title: '3분 다정 안부 타임',
    message:
      '오늘 하루 수고한 서로에게 "오늘 제일 기분 좋았던 순간"을 물어봐 주는 3분 타임, 가볍게 시작해 볼까요?',
    badge: '다정함 리마인더',
    time: '2일 전',
    icon: 'coffee',
    accepted: true,
    acceptedAt: '2일 전 완료',
    bookmarked: true,
    fromNudge: false,
  },
];

// 입력 문장에서 키워드 기반으로 가장 적합한 넛지 카테고리 매칭
function detectNudgeCategory(text) {
  const lower = text.toLowerCase();
  if (/폰|스마트폰|핸드폰|휴대폰|유튜브|인스타|릴스|쇼츠|게임|화면|만 보|만봐/.test(lower)) {
    return 'phone';
  }
  if (/연락|답장|읽씹|안읽|카톡|톡|전화|바빠|바쁘|바쁨|무소식|기다리/.test(lower)) {
    return 'contact';
  }
  if (/표현|사랑|좋아|예쁘|애정|스킨십|안아|고마|관심|무심|외로|설렘/.test(lower)) {
    return 'affection';
  }
  if (/데이트|코스|계획|약속|주말|어디|식당|카페|매번 나만|맨날 나만/.test(lower)) {
    return 'date';
  }
  if (/말투|짜증|화내|차가|무뚝뚝|단답|퉁명|상처|예민|소리/.test(lower)) {
    return 'tone';
  }
  return 'default';
}

function formatNowTime() {
  const now = new Date();
  const hours = now.getHours();
  const minutes = String(now.getMinutes()).padStart(2, '0');
  const period = hours >= 12 ? '오후' : '오전';
  const h12 = hours % 12 === 0 ? 12 : hours % 12;
  return `${period} ${h12}:${minutes}`;
}

function getWarmthStage(temp) {
  if (temp >= 42) return { label: '달콤한 열기', emoji: '🔥' };
  if (temp >= 39.5) return { label: '포근한 햇살', emoji: '☀️' };
  if (temp >= 37.5) return { label: '따뜻한 봄날', emoji: '🌸' };
  return { label: '잔잔한 미풍', emoji: '🌿' };
}

function MissionIcon({ type, className = 'w-4 h-4' }) {
  switch (type) {
    case 'gift':
      return <Gift className={className} />;
    case 'coffee':
      return <Coffee className={className} />;
    case 'calendar':
      return <CalendarHeart className={className} />;
    case 'smile':
      return <Smile className={className} />;
    case 'heart':
      return <Heart className={className} />;
    default:
      return <Sparkles className={className} />;
  }
}

export default function App() {
  // 뷰 모드: 'dual' | 'A' | 'B'
  const [viewMode, setViewMode] = useState('dual');
  const [aSubTab, setASubTab] = useState('chat'); // 'chat' | 'history'

  // 공통 커플 지표
  const [warmthTemp, setWarmthTemp] = useState(37.5);
  const [completedCount, setCompletedCount] = useState(2);

  // A의 채팅 및 넛지 히스토리
  const [inputText, setInputText] = useState('');
  const [isTyping, setIsTyping] = useState(false);
  const [chatMessages, setChatMessages] = useState([
    {
      id: 'welcome-1',
      sender: 'bot',
      type: 'welcome',
      text: '안녕! 나는 두 사람 사이를 포근하게 이어주는 수호천사 사이봇이야. 오늘 연인에게 서운했거나 아쉬웠던 점을 솔직하게 털어놓아 주세요. (상대방에겐 절대 그대로 전달되지 않아요 🤫)',
      time: '방금 전',
    },
  ]);
  const [sentHistory, setSentHistory] = useState([]);

  // B의 미션 피드
  const [partnerMissions, setPartnerMissions] = useState(INITIAL_PARTNER_MISSIONS);

  // 알림 & 인터랙션 피드백
  const [aBannerNotice, setABannerNotice] = useState(null);
  const [bUnreadCount, setBUnreadCount] = useState(0);
  const [aUnreadCount, setAUnreadCount] = useState(0);
  const [signalPulse, setSignalPulse] = useState(null); // 'AtoB' | 'BtoA' | null

  // 초안 편집 상태
  const [editingDraftId, setEditingDraftId] = useState(null);
  const [editingDraftText, setEditingDraftText] = useState('');

  // Gemini API 연동 구조 안내 모달 (선택적 고급 설정)
  const [showApiModal, setShowApiModal] = useState(false);
  const [engineMode, setEngineMode] = useState('smart'); // 'smart' | 'gemini'
  const [geminiApiKey, setGeminiApiKey] = useState('');
  const [apiNotice, setApiNotice] = useState('');

  const chatEndRef = useRef(null);
  const bTopRef = useRef(null);

  useEffect(() => {
    if (chatEndRef.current) {
      chatEndRef.current.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }
  }, [chatMessages, isTyping]);

  // 뷰 전환 시 배지 초기화
  const handleSwitchView = (mode) => {
    setViewMode(mode);
    if (mode === 'B' || mode === 'dual') setBUnreadCount(0);
    if (mode === 'A' || mode === 'dual') setAUnreadCount(0);
  };

  // 전체 프로토타입 초기화
  const handleResetDemo = () => {
    setWarmthTemp(37.5);
    setCompletedCount(2);
    setInputText('');
    setIsTyping(false);
    setChatMessages([
      {
        id: 'welcome-1',
        sender: 'bot',
        type: 'welcome',
        text: '안녕! 나는 두 사람 사이를 포근하게 이어주는 수호천사 사이봇이야. 오늘 연인에게 서운했거나 아쉬웠던 점을 솔직하게 털어놓아 주세요. (상대방에겐 절대 그대로 전달되지 않아요 🤫)',
        time: '방금 전',
      },
    ]);
    setSentHistory([]);
    setPartnerMissions(INITIAL_PARTNER_MISSIONS);
    setABannerNotice(null);
    setBUnreadCount(0);
    setAUnreadCount(0);
    setSignalPulse(null);
    setEditingDraftId(null);
    setASubTab('chat');
  };

  // Gemini API 선택 호출 (키 입력 시) 또는 스마트 매칭 엔진 fallback
  const generateTranslation = async (rawText) => {
    const catKey = detectNudgeCategory(rawText);
    const preset = NUDGE_LIBRARY[catKey] || NUDGE_LIBRARY.default;

    if (engineMode === 'gemini' && geminiApiKey.trim()) {
      try {
        const prompt = `당신은 커플 관계 코칭 AI '사이봇'입니다. 연인 A가 서운한 감정을 털어놓았습니다: "${rawText}"
반드시 아래 JSON 형식으로만 답하세요(마크다운 코드블록 없이):
{"empathy":"A를 깊이 공감하고 위로하는 따뜻한 한국어 2문장","title":"B에게 보낼 자연스러운 데일리 미션 제목(15자 이내)","message":"A의 서운함이 전혀 티 나지 않는 자연스러운 커플 데일리 미션 문구(한국어 2문장)"}`;

        const res = await fetch(
          `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${encodeURIComponent(
            geminiApiKey.trim()
          )}`,
          {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              contents: [{ parts: [{ text: prompt }] }],
            }),
          }
        );

        if (res.ok) {
          const data = await res.json();
          const rawOut = data?.candidates?.[0]?.content?.parts?.[0]?.text || '';
          const cleaned = rawOut.replace(/```json|```/g, '').trim();
          const parsed = JSON.parse(cleaned);
          if (parsed.empathy && parsed.message) {
            return {
              categoryKey: catKey,
              tagName: preset.tagName,
              empathy: parsed.empathy,
              drafts: [
                {
                  title: parsed.title || '오늘의 다정함 미션',
                  message: parsed.message,
                  badge: '오늘의 데일리 미션',
                  icon: 'sparkles',
                },
                ...preset.drafts,
              ],
            };
          }
        }
      } catch (_err) {
        // API 실패 시 로컬 스마트 매칭 엔진으로 자연스럽게 폴백
      }
    }

    return {
      categoryKey: catKey,
      tagName: preset.tagName,
      empathy: preset.empathy,
      drafts: preset.drafts,
    };
  };

  // A의 감정 전송 핸들러
  const handleSendEmotion = async (customText) => {
    const text = (typeof customText === 'string' ? customText : inputText).trim();
    if (!text || isTyping) return;

    const nowTime = formatNowTime();
    const userMsgId = `user-${Date.now()}`;

    setChatMessages((prev) => [
      ...prev,
      {
        id: userMsgId,
        sender: 'user',
        text,
        time: nowTime,
      },
    ]);
    setInputText('');
    setIsTyping(true);
    setASubTab('chat');

    // 자연스러운 공감 타이핑 딜레이
    const [result] = await Promise.all([
      generateTranslation(text),
      new Promise((resolve) => setTimeout(resolve, 750)),
    ]);

    const botReplyId = `bot-${Date.now()}`;
    setChatMessages((prev) => [
      ...prev,
      {
        id: botReplyId,
        sender: 'bot',
        type: 'empathy_and_draft',
        empathy: result.empathy,
        tagName: result.tagName,
        drafts: result.drafts,
        activeDraftIdx: 0,
        customMessage: null,
        sent: false,
        acceptedByPartner: false,
        linkedMissionId: null,
        rawOrigin: text,
        time: formatNowTime(),
      },
    ]);
    setIsTyping(false);
  };

  // 초안 문구 다른 표현으로 변경
  const handleShuffleDraft = (msgId) => {
    setChatMessages((prev) =>
      prev.map((m) => {
        if (m.id !== msgId || m.sent) return m;
        const nextIdx = (m.activeDraftIdx + 1) % m.drafts.length;
        return { ...m, activeDraftIdx: nextIdx, customMessage: null };
      })
    );
    if (editingDraftId === msgId) {
      setEditingDraftId(null);
    }
  };

  // 초안 직접 수정 시작/저장
  const handleStartEditDraft = (msg) => {
    const currentText = msg.customMessage ?? msg.drafts[msg.activeDraftIdx].message;
    setEditingDraftId(msg.id);
    setEditingDraftText(currentText);
  };

  const handleSaveEditDraft = (msgId) => {
    if (!editingDraftText.trim()) return;
    setChatMessages((prev) =>
      prev.map((m) =>
        m.id === msgId ? { ...m, customMessage: editingDraftText.trim() } : m
      )
    );
    setEditingDraftId(null);
  };

  // [이대로 슬쩍 신호 보내기] 클릭 -> B의 피드로 자연스러운 미션 전송
  const handleSendNudgeToPartner = (msg) => {
    if (msg.sent) return;
    const chosenDraft = msg.drafts[msg.activeDraftIdx];
    const finalMessage = msg.customMessage ?? chosenDraft.message;
    const missionId = `nudge-${Date.now()}`;
    const timeStr = '방금 도착';

    // A 메시지 상태 업데이트
    setChatMessages((prev) =>
      prev.map((m) =>
        m.id === msg.id
          ? { ...m, sent: true, linkedMissionId: missionId, sentMessage: finalMessage }
          : m
      )
    );

    // A 보낸 신호 히스토리에 추가
    setSentHistory((prev) => [
      {
        id: missionId,
        tagName: msg.tagName,
        rawOrigin: msg.rawOrigin,
        missionTitle: chosenDraft.title,
        missionMessage: finalMessage,
        sentTime: formatNowTime(),
        status: 'waiting', // 'waiting' | 'accepted'
      },
      ...prev,
    ]);

    // B 피드 최상단에 자연스러운 데일리 미션으로 삽입 (서운함 단서 0%)
    const newPartnerCard = {
      id: missionId,
      title: chosenDraft.title,
      message: finalMessage,
      badge: chosenDraft.badge || '오늘의 커플 추천 팁',
      time: timeStr,
      icon: chosenDraft.icon || 'sparkles',
      accepted: false,
      bookmarked: false,
      fromNudge: true,
      isNew: true,
    };

    setPartnerMissions((prev) => [newPartnerCard, ...prev]);

    // 시그널 애니메이션 및 B 알림 배지
    setSignalPulse('AtoB');
    setTimeout(() => setSignalPulse(null), 1800);

    if (viewMode === 'A') {
      setBUnreadCount((c) => c + 1);
    }

    if (bTopRef.current) {
      bTopRef.current.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }
  };

  // B가 [오늘 해볼게요! 💛] 클릭 시 처리
  const handleAcceptMission = (mission) => {
    if (mission.accepted) return;

    // B 카드 스탬프 처리
    setPartnerMissions((prev) =>
      prev.map((item) =>
        item.id === mission.id
          ? { ...item, accepted: true, acceptedAt: '방금 수락함', isNew: false }
          : item
      )
    );

    // 애정 온도계 & 다정함 지수 상승
    setWarmthTemp((prev) => Math.min(45.0, Number((prev + 1.2).toFixed(1))));
    setCompletedCount((prev) => prev + 1);

    // A의 보낸 기록 & 채팅 카드 업데이트
    setChatMessages((prev) => {
      const updated = prev.map((m) =>
        m.linkedMissionId === mission.id ? { ...m, acceptedByPartner: true } : m
      );
      return [
        ...updated,
        {
          id: `notice-${Date.now()}`,
          sender: 'bot',
          type: 'partner_accepted',
          missionTitle: mission.title,
          text: `기분 좋은 소식이에요! 상대방이 오늘의 추천 미션("${mission.title}")을 수락했어요! 💛`,
          time: formatNowTime(),
        },
      ];
    });

    setSentHistory((prev) =>
      prev.map((h) =>
        h.id === mission.id ? { ...h, status: 'accepted', acceptedTime: formatNowTime() } : h
      )
    );

    // A 상단 알림 배너 표시
    setABannerNotice({
      id: Date.now(),
      text: '상대방이 오늘의 추천 미션을 수락했어요! 💛',
      sub: `다정함 온도가 +1.2°C 올라갔어요`,
    });

    setSignalPulse('BtoA');
    setTimeout(() => setSignalPulse(null), 1800);

    if (viewMode === 'B') {
      setAUnreadCount((c) => c + 1);
    }
  };

  // B 북마크(나중에 보기) 토글
  const handleToggleBookmark = (missionId) => {
    setPartnerMissions((prev) =>
      prev.map((item) =>
        item.id === missionId ? { ...item, bookmarked: !item.bookmarked } : item
      )
    );
  };

  const warmthStage = getWarmthStage(warmthTemp);
  const warmthPercent = Math.min(100, Math.max(10, ((warmthTemp - 35) / 10) * 100));

  // iPhone 프레임 공통 상단 상태바
  const PhoneStatusBar = ({ label, accentBg }) => (
    <div className="px-6 pt-3 pb-2 flex items-center justify-between text-[11px] font-semibold text-[#2D3436] select-none">
      <span>9:41</span>
      <div className="w-24 h-5 bg-[#2D3436] rounded-full flex items-center justify-center">
        <span className={`w-1.5 h-1.5 rounded-full ${accentBg} mr-1.5`} />
        <span className="text-[9px] text-white/90 tracking-tight font-medium">{label}</span>
      </div>
      <div className="flex items-center gap-1 text-[#2D3436]">
        <Signal className="w-3 h-3" />
        <Wifi className="w-3 h-3" />
        <Battery className="w-3.5 h-3.5" />
      </div>
    </div>
  );

  // ==================== [나의 화면 (A)] 렌더링 ====================
  const renderPhoneA = () => (
    <div className="flex flex-col items-center w-full">
      {/* 역할 라벨 */}
      <div className="mb-3 flex items-center gap-2 px-3.5 py-1.5 rounded-full bg-white shadow-sm border border-[#FF8A80]/25">
        <span className="w-2.5 h-2.5 rounded-full bg-[#FF8A80]" />
        <span className="text-xs font-bold text-[#2D3436]">나의 화면 (A · 지수)</span>
        <span className="text-[11px] text-[#636E72]">감정 털어놓기 & AI 번역</span>
      </div>

      {/* iPhone 프레임 */}
      <div className="w-full max-w-[400px] h-[740px] bg-[#FFF9F5] rounded-[42px] border-[8px] border-[#2D3436] shadow-[0_20px_50px_rgba(45,52,54,0.14)] flex flex-col overflow-hidden relative">
        <PhoneStatusBar label="우리사이 · 나" accentBg="bg-[#FF8A80]" />

        {/* 앱 헤더 */}
        <div className="px-5 pt-1 pb-3 bg-[#FFF9F5] border-b border-[#FF8A80]/15">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2.5">
              <img
                src={SAIBOT_AVATAR}
                alt="사이봇"
                className="w-10 h-10 rounded-2xl object-cover border border-[#FF8A80]/30 shadow-sm"
              />
              <div>
                <div className="flex items-center gap-1.5">
                  <h2 className="text-base font-extrabold text-[#2D3436] tracking-tight">사이봇</h2>
                  <span className="text-[10px] font-semibold px-2 py-0.5 rounded-full bg-[#FF8A80]/15 text-[#E0665B]">
                    비밀 수호천사
                  </span>
                </div>
                <p className="text-[11px] text-[#636E72] flex items-center gap-1">
                  <Lock className="w-3 h-3 text-[#FF8A80]" />
                  대화 내용은 나만 볼 수 있어요
                </p>
              </div>
            </div>

            {/* A 내부 탭 전환 */}
            <div className="flex bg-white p-1 rounded-xl border border-[#2D3436]/10 shadow-sm">
              <button
                type="button"
                onClick={() => setASubTab('chat')}
                className={`px-2.5 py-1 rounded-lg text-[11px] font-semibold transition-all ${
                  aSubTab === 'chat'
                    ? 'bg-[#FF8A80] text-white shadow-sm'
                    : 'text-[#636E72] hover:text-[#2D3436]'
                }`}
              >
                상담
              </button>
              <button
                type="button"
                onClick={() => setASubTab('history')}
                className={`px-2.5 py-1 rounded-lg text-[11px] font-semibold transition-all flex items-center gap-1 ${
                  aSubTab === 'history'
                    ? 'bg-[#FF8A80] text-white shadow-sm'
                    : 'text-[#636E72] hover:text-[#2D3436]'
                }`}
              >
                기록
                {sentHistory.length > 0 && (
                  <span
                    className={`px-1 rounded-full text-[9px] ${
                      aSubTab === 'history' ? 'bg-white/25 text-white' : 'bg-[#FF8A80]/20 text-[#E0665B]'
                    }`}
                  >
                    {sentHistory.length}
                  </span>
                )}
              </button>
            </div>
          </div>

          {/* 미니 애정 온도계 */}
          <div className="mt-3 bg-white rounded-2xl px-3.5 py-2.5 shadow-[0_2px_12px_rgba(45,52,54,0.04)] border border-[#FF8A80]/15">
            <div className="flex items-center justify-between text-[11px] mb-1.5">
              <span className="font-bold text-[#2D3436] flex items-center gap-1">
                <Thermometer className="w-3.5 h-3.5 text-[#FF8A80]" />
                우리의 다정함 온도
              </span>
              <span className="font-extrabold text-[#FF8A80]">
                {warmthTemp.toFixed(1)}°C <span className="font-medium text-[#636E72]">· {warmthStage.label}</span>
              </span>
            </div>
            <div className="w-full h-2 bg-[#FFF0EE] rounded-full overflow-hidden">
              <div
                className="h-full bg-gradient-to-r from-[#FFAB91] to-[#FF8A80] rounded-full transition-all duration-700"
                style={{ width: `${warmthPercent}%` }}
              />
            </div>
          </div>
        </div>

        {/* 상대방 수락 시 기분 좋은 푸시 알림 배너 */}
        {aBannerNotice && (
          <div className="mx-4 mt-2.5 bg-[#2D3436] text-white rounded-2xl px-3.5 py-2.5 shadow-lg flex items-center justify-between gap-2 animate-pulse">
            <div className="flex items-center gap-2.5 min-w-0">
              <div className="w-8 h-8 rounded-xl bg-[#FF8A80] flex items-center justify-center shrink-0">
                <Bell className="w-4 h-4 text-white" />
              </div>
              <div className="min-w-0">
                <p className="text-xs font-bold truncate">{aBannerNotice.text}</p>
                <p className="text-[10px] text-white/75">{aBannerNotice.sub}</p>
              </div>
            </div>
            <button
              type="button"
              onClick={() => setABannerNotice(null)}
              className="p-1 text-white/60 hover:text-white"
              aria-label="알림 닫기"
            >
              <X className="w-3.5 h-3.5" />
            </button>
          </div>
        )}

        {/* 본문: 상담 채팅 vs 보낸 신호 기록 */}
        {aSubTab === 'chat' ? (
          <>
            <div className="flex-1 overflow-y-auto px-4 py-3.5 space-y-3.5">
              {chatMessages.map((msg) => {
                // 1) A의 날것 감정 버블
                if (msg.sender === 'user') {
                  return (
                    <div key={msg.id} className="flex flex-col items-end">
                      <div className="max-w-[85%] bg-[#2D3436] text-white rounded-2xl rounded-tr-sm px-3.5 py-2.5 shadow-sm">
                        <p className="text-[13px] leading-relaxed">{msg.text}</p>
                      </div>
                      <span className="mt-1 text-[10px] text-[#9AA5A9] flex items-center gap-1">
                        <Lock className="w-2.5 h-2.5" /> 나만 보는 기록 · {msg.time}
                      </span>
                    </div>
                  );
                }

                // 2) 상대방 미션 수락 알림 버블
                if (msg.type === 'partner_accepted') {
                  return (
                    <div key={msg.id} className="flex justify-center">
                      <div className="w-full bg-gradient-to-r from-[#FFF0EE] to-[#FFF8E7] border border-[#FF8A80]/30 rounded-2xl px-3.5 py-2.5 flex items-center gap-2.5 shadow-sm">
                        <div className="w-8 h-8 rounded-full bg-[#FF8A80]/20 flex items-center justify-center shrink-0">
                          <Heart className="w-4 h-4 text-[#FF8A80] fill-[#FF8A80]" />
                        </div>
                        <div className="flex-1">
                          <p className="text-xs font-bold text-[#2D3436] leading-snug">{msg.text}</p>
                          <p className="text-[10px] text-[#636E72] mt-0.5">{msg.time}</p>
                        </div>
                      </div>
                    </div>
                  );
                }

                // 3) 사이봇 웰컴 메시지
                if (msg.type === 'welcome') {
                  return (
                    <div key={msg.id} className="flex items-start gap-2">
                      <img
                        src={SAIBOT_AVATAR}
                        alt="사이봇"
                        className="w-8 h-8 rounded-full object-cover border border-[#FF8A80]/30 shrink-0 mt-0.5"
                      />
                      <div className="max-w-[85%]">
                        <div className="bg-white rounded-2xl rounded-tl-sm px-3.5 py-3 shadow-[0_4px_16px_rgba(45,52,54,0.05)] border border-[#FF8A80]/15">
                          <p className="text-[13px] text-[#2D3436] leading-relaxed">{msg.text}</p>
                        </div>
                        <span className="mt-1 block text-[10px] text-[#9AA5A9]">{msg.time}</span>
                      </div>
                    </div>
                  );
                }

                // 4) 사이봇 공감 답장 + 시치미 뚝 뗀 넛지 초안 카드
                const activeDraft = msg.drafts[msg.activeDraftIdx];
                const displayDraftMsg = msg.customMessage ?? activeDraft.message;
                const isEditing = editingDraftId === msg.id;

                return (
                  <div key={msg.id} className="flex items-start gap-2">
                    <img
                      src={SAIBOT_AVATAR}
                      alt="사이봇"
                      className="w-8 h-8 rounded-full object-cover border border-[#FF8A80]/30 shrink-0 mt-0.5"
                    />
                    <div className="flex-1 space-y-2.5 min-w-0">
                      {/* 공감 & 위로 말풍선 */}
                      <div className="bg-white rounded-2xl rounded-tl-sm px-3.5 py-3 shadow-[0_4px_16px_rgba(45,52,54,0.05)] border border-[#FF8A80]/15">
                        <div className="flex items-center gap-1.5 mb-1">
                          <MessageCircleHeart className="w-3.5 h-3.5 text-[#FF8A80]" />
                          <span className="text-[11px] font-bold text-[#FF8A80]">사이봇의 공감</span>
                        </div>
                        <p className="text-[13px] text-[#2D3436] leading-relaxed">{msg.empathy}</p>
                      </div>

                      {/* 시치미 뚝 뗀 넛지 초안 미리보기 카드 */}
                      <div className="bg-gradient-to-br from-white to-[#FFF3F0] rounded-2xl p-3.5 shadow-[0_6px_24px_rgba(255,138,128,0.14)] border border-[#FF8A80]/35">
                        <div className="flex items-center justify-between gap-2 mb-2">
                          <span className="inline-flex items-center gap-1 text-[10px] font-bold px-2 py-0.5 rounded-full bg-[#FF8A80]/15 text-[#D95B50]">
                            <Wand2 className="w-3 h-3" />
                            시치미 뚝 뗀 넛지 초안
                          </span>
                          {!msg.sent && (
                            <div className="flex items-center gap-1">
                              <button
                                type="button"
                                onClick={() => handleShuffleDraft(msg.id)}
                                className="p-1 rounded-lg text-[#636E72] hover:text-[#FF8A80] hover:bg-white transition-colors"
                                title="다른 표현으로 바꾸기"
                              >
                                <RefreshCw className="w-3.5 h-3.5" />
                              </button>
                              <button
                                type="button"
                                onClick={() => handleStartEditDraft(msg)}
                                className="p-1 rounded-lg text-[#636E72] hover:text-[#FF8A80] hover:bg-white transition-colors"
                                title="문구 직접 다듬기"
                              >
                                <Edit3 className="w-3.5 h-3.5" />
                              </button>
                            </div>
                          )}
                        </div>

                        {/* 상대방에게 보일 실제 카드 미리보기 */}
                        <div className="bg-white/90 rounded-xl p-3 border border-[#FF8A80]/15">
                          <div className="flex items-center gap-1.5 mb-1">
                            <span className="text-[10px] font-semibold text-[#FF8A80]">
                              {activeDraft.badge}
                            </span>
                            <span className="text-[10px] text-[#9AA5A9]">· {activeDraft.title}</span>
                          </div>

                          {isEditing ? (
                            <div className="space-y-2 mt-1.5">
                              <textarea
                                value={editingDraftText}
                                onChange={(e) => setEditingDraftText(e.target.value)}
                                rows={3}
                                className="w-full text-xs text-[#2D3436] bg-[#FFF9F5] border border-[#FF8A80]/40 rounded-xl p-2 focus:outline-none focus:ring-2 focus:ring-[#FF8A80]/40 resize-none"
                              />
                              <div className="flex justify-end gap-1.5">
                                <button
                                  type="button"
                                  onClick={() => setEditingDraftId(null)}
                                  className="px-2.5 py-1 rounded-lg text-[11px] font-semibold text-[#636E72] bg-gray-100 hover:bg-gray-200"
                                >
                                  취소
                                </button>
                                <button
                                  type="button"
                                  onClick={() => handleSaveEditDraft(msg.id)}
                                  className="px-2.5 py-1 rounded-lg text-[11px] font-semibold text-white bg-[#FF8A80] hover:bg-[#F26D63] flex items-center gap-1"
                                >
                                  <Check className="w-3 h-3" /> 저장
                                </button>
                              </div>
                            </div>
                          ) : (
                            <p className="text-[12.5px] text-[#2D3436] leading-relaxed font-medium">
                              “{displayDraftMsg}”
                            </p>
                          )}
                        </div>

                        <p className="mt-2 text-[10px] text-[#636E72] flex items-center gap-1">
                          <ShieldCheck className="w-3 h-3 text-[#FF8A80] shrink-0" />
                          상대방에겐 평소 오는 커플 추천 팁처럼 자연스럽게 도착해요
                        </p>

                        {/* 전송 버튼 / 상태 표시 */}
                        <div className="mt-2.5">
                          {!msg.sent ? (
                            <button
                              type="button"
                              onClick={() => handleSendNudgeToPartner(msg)}
                              className="w-full py-2.5 px-4 rounded-xl bg-[#FF8A80] hover:bg-[#F26D63] active:scale-[0.99] text-white text-xs font-bold shadow-[0_4px_14px_rgba(255,138,128,0.4)] transition-all flex items-center justify-center gap-1.5"
                            >
                              <Sparkles className="w-3.5 h-3.5" />
                              이대로 슬쩍 신호 보내기
                            </button>
                          ) : msg.acceptedByPartner ? (
                            <div className="w-full py-2 px-3 rounded-xl bg-[#E8F8F0] text-[#1E8449] text-xs font-bold flex items-center justify-center gap-1.5 border border-[#A9DFBF]">
                              <CheckCircle2 className="w-4 h-4" />
                              상대방이 미션을 수락했어요! 💛
                            </div>
                          ) : (
                            <div className="w-full py-2 px-3 rounded-xl bg-[#FFF0EE] text-[#E0665B] text-xs font-semibold flex items-center justify-center gap-1.5 border border-[#FF8A80]/30">
                              <Check className="w-3.5 h-3.5" />
                              상대방 피드에 자연스럽게 도착했어요
                            </div>
                          )}
                        </div>
                      </div>
                      <span className="block text-[10px] text-[#9AA5A9]">{msg.time}</span>
                    </div>
                  </div>
                );
              })}

              {/* 타이핑 인디케이터 */}
              {isTyping && (
                <div className="flex items-start gap-2">
                  <img
                    src={SAIBOT_AVATAR}
                    alt="사이봇"
                    className="w-8 h-8 rounded-full object-cover border border-[#FF8A80]/30"
                  />
                  <div className="bg-white rounded-2xl rounded-tl-sm px-3.5 py-2.5 border border-[#FF8A80]/15 shadow-sm flex items-center gap-2">
                    <span className="text-xs text-[#636E72]">사이봇이 마음을 번역하는 중</span>
                    <span className="flex gap-1">
                      <span className="w-1.5 h-1.5 rounded-full bg-[#FF8A80] animate-bounce" />
                      <span
                        className="w-1.5 h-1.5 rounded-full bg-[#FF8A80] animate-bounce"
                        style={{ animationDelay: '150ms' }}
                      />
                      <span
                        className="w-1.5 h-1.5 rounded-full bg-[#FF8A80] animate-bounce"
                        style={{ animationDelay: '300ms' }}
                      />
                    </span>
                  </div>
                </div>
              )}
              <div ref={chatEndRef} />
            </div>

            {/* 빠른 선택 태그 & 입력 영역 */}
            <div className="bg-white border-t border-[#FF8A80]/15 px-3.5 pt-2.5 pb-4">
              {/* 빠른 태그 */}
              <div className="flex gap-1.5 overflow-x-auto pb-2 no-scrollbar">
                {QUICK_TAGS.map((tag) => (
                  <button
                    key={tag.id}
                    type="button"
                    onClick={() => setInputText(tag.sample)}
                    className="shrink-0 px-2.5 py-1 rounded-full text-[11px] font-semibold bg-[#FFF9F5] text-[#2D3436] border border-[#FF8A80]/30 hover:bg-[#FF8A80] hover:text-white transition-colors"
                  >
                    {tag.label}
                  </button>
                ))}
              </div>

              {/* 입력창 */}
              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  handleSendEmotion();
                }}
                className="flex items-end gap-2 bg-[#FFF9F5] rounded-2xl border border-[#FF8A80]/30 px-3 py-2 focus-within:ring-2 focus-within:ring-[#FF8A80]/40"
              >
                <textarea
                  value={inputText}
                  onChange={(e) => setInputText(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' && !e.shiftKey) {
                      e.preventDefault();
                      handleSendEmotion();
                    }
                  }}
                  rows={2}
                  placeholder="오늘 연인에게 서운했거나 아쉬웠던 점을 솔직하게 털어놓아 주세요..."
                  className="flex-1 bg-transparent text-[12.5px] text-[#2D3436] placeholder-[#9AA5A9] focus:outline-none resize-none leading-snug"
                />
                <button
                  type="submit"
                  disabled={!inputText.trim() || isTyping}
                  className="w-9 h-9 rounded-xl bg-[#FF8A80] hover:bg-[#F26D63] disabled:opacity-40 text-white flex items-center justify-center shrink-0 transition-all shadow-sm"
                  aria-label="감정 전송"
                >
                  <Send className="w-4 h-4" />
                </button>
              </form>
            </div>
          </>
        ) : (
          /* 보낸 신호 기록 탭 */
          <div className="flex-1 overflow-y-auto px-4 py-4 space-y-3">
            <div className="flex items-center justify-between">
              <h3 className="text-xs font-bold text-[#2D3436]">내가 슬쩍 보낸 다정함 신호</h3>
              <span className="text-[11px] text-[#636E72]">총 {sentHistory.length}건</span>
            </div>

            {sentHistory.length === 0 ? (
              <div className="bg-white rounded-2xl p-6 text-center border border-[#FF8A80]/15 mt-4">
                <div className="w-12 h-12 rounded-2xl bg-[#FFF0EE] flex items-center justify-center mx-auto mb-3">
                  <Sparkles className="w-6 h-6 text-[#FF8A80]" />
                </div>
                <p className="text-xs font-bold text-[#2D3436]">아직 보낸 신호가 없어요</p>
                <p className="text-[11px] text-[#636E72] mt-1 leading-relaxed">
                  상담 탭에서 서운했던 마음을 털어놓으면
                  <br />
                  사이봇이 부드러운 미션으로 번역해 드려요.
                </p>
              </div>
            ) : (
              sentHistory.map((item) => (
                <div
                  key={item.id}
                  className="bg-white rounded-2xl p-3.5 border border-[#FF8A80]/20 shadow-sm space-y-2"
                >
                  <div className="flex items-center justify-between">
                    <span className="text-[10px] font-bold px-2 py-0.5 rounded-full bg-[#FFF0EE] text-[#E0665B]">
                      #{item.tagName}
                    </span>
                    {item.status === 'accepted' ? (
                      <span className="text-[10px] font-bold text-[#1E8449] bg-[#E8F8F0] px-2 py-0.5 rounded-full flex items-center gap-1">
                        <CheckCircle2 className="w-3 h-3" /> 수락 완료 💛
                      </span>
                    ) : (
                      <span className="text-[10px] font-semibold text-[#636E72] flex items-center gap-1">
                        <Clock className="w-3 h-3" /> 도착 완료
                      </span>
                    )}
                  </div>
                  <div className="bg-[#FFF9F5] rounded-xl p-2.5 text-[11px] text-[#636E72]">
                    <span className="font-semibold text-[#2D3436]">내 속마음: </span>
                    {item.rawOrigin}
                  </div>
                  <div className="text-xs text-[#2D3436] leading-relaxed">
                    <span className="font-bold text-[#FF8A80]">번역된 미션 · </span>
                    {item.missionMessage}
                  </div>
                  <p className="text-[10px] text-[#9AA5A9] text-right">{item.sentTime}</p>
                </div>
              ))
            )}
          </div>
        )}

        {/* iPhone 홈 인디케이터 */}
        <div className="bg-white py-2 flex justify-center">
          <div className="w-28 h-1 rounded-full bg-[#2D3436]/20" />
        </div>
      </div>
    </div>
  );

  // ==================== [상대방의 화면 (B)] 렌더링 ====================
  const renderPhoneB = () => (
    <div className="flex flex-col items-center w-full">
      {/* 역할 라벨 */}
      <div className="mb-3 flex items-center gap-2 px-3.5 py-1.5 rounded-full bg-white shadow-sm border border-[#FFB74D]/40">
        <span className="w-2.5 h-2.5 rounded-full bg-[#FFB74D]" />
        <span className="text-xs font-bold text-[#2D3436]">상대방의 화면 (B · 민준)</span>
        <span className="text-[11px] text-[#636E72]">자연스러운 데일리 미션 수신</span>
      </div>

      {/* iPhone 프레임 */}
      <div className="w-full max-w-[400px] h-[740px] bg-[#FFF9F5] rounded-[42px] border-[8px] border-[#2D3436] shadow-[0_20px_50px_rgba(45,52,54,0.14)] flex flex-col overflow-hidden relative">
        <PhoneStatusBar label="우리사이 · 데일리" accentBg="bg-[#FFB74D]" />

        {/* B 앱 헤더 (A의 불만 흔적 전혀 없음) */}
        <div className="px-5 pt-1 pb-3.5 bg-[#FFF9F5] border-b border-[#FF8A80]/15">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-[11px] font-semibold text-[#FF8A80]">지수 ♥ 민준 · D+342</p>
              <h2 className="text-lg font-extrabold text-[#2D3436] tracking-tight">
                오늘의 우리사이
              </h2>
            </div>
            <div className="flex items-center gap-1.5 bg-white px-3 py-1.5 rounded-2xl border border-[#FF8A80]/20 shadow-sm">
              <Heart className="w-4 h-4 text-[#FF8A80] fill-[#FF8A80]" />
              <span className="text-xs font-extrabold text-[#2D3436]">{warmthTemp.toFixed(1)}°C</span>
            </div>
          </div>

          {/* 다정함 지수 게이지 카드 */}
          <div className="mt-3 bg-gradient-to-r from-[#FF8A80] to-[#FFA096] rounded-2xl p-3.5 text-white shadow-[0_6px_20px_rgba(255,138,128,0.3)]">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-[10px] font-semibold text-white/85">이번 주 다정함 지수</p>
                <p className="text-sm font-extrabold mt-0.5">
                  {warmthStage.emoji} {warmthStage.label} · 미션 {completedCount}회 달성
                </p>
              </div>
              <div className="w-10 h-10 rounded-2xl bg-white/20 backdrop-blur-sm flex items-center justify-center">
                <Sparkles className="w-5 h-5 text-white" />
              </div>
            </div>
            <div className="mt-2.5 w-full h-1.5 bg-white/30 rounded-full overflow-hidden">
              <div
                className="h-full bg-white rounded-full transition-all duration-700"
                style={{ width: `${warmthPercent}%` }}
              />
            </div>
          </div>
        </div>

        {/* 데일리 미션 피드 */}
        <div className="flex-1 overflow-y-auto px-4 py-3.5 space-y-3">
          <div ref={bTopRef} />
          <div className="flex items-center justify-between px-0.5">
            <span className="text-xs font-bold text-[#2D3436]">도착한 커플 추천 팁</span>
            <span className="text-[11px] text-[#636E72]">
              대기 중 {partnerMissions.filter((m) => !m.accepted).length}개
            </span>
          </div>

          {partnerMissions.map((mission) => (
            <div
              key={mission.id}
              className={`relative bg-white rounded-2xl p-4 border transition-all duration-300 ${
                mission.isNew && !mission.accepted
                  ? 'border-[#FF8A80] shadow-[0_8px_24px_rgba(255,138,128,0.18)] ring-2 ring-[#FF8A80]/20'
                  : 'border-[#2D3436]/8 shadow-[0_4px_16px_rgba(45,52,54,0.05)]'
              }`}
            >
              {/* 카드 상단 배지 */}
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center gap-1.5">
                  <span className="w-6 h-6 rounded-xl bg-[#FFF0EE] text-[#FF8A80] flex items-center justify-center">
                    <MissionIcon type={mission.icon} className="w-3.5 h-3.5" />
                  </span>
                  <span className="text-[11px] font-bold text-[#FF8A80]">{mission.badge}</span>
                  {mission.isNew && !mission.accepted && (
                    <span className="px-1.5 py-0.5 rounded-md bg-[#FF8A80] text-white text-[9px] font-extrabold tracking-wide">
                      NEW
                    </span>
                  )}
                </div>

                <div className="flex items-center gap-1.5">
                  <span className="text-[10px] text-[#9AA5A9]">{mission.time}</span>
                  <button
                    type="button"
                    onClick={() => handleToggleBookmark(mission.id)}
                    className={`p-1 rounded-lg transition-colors ${
                      mission.bookmarked
                        ? 'text-[#FFB74D] bg-[#FFF8E7]'
                        : 'text-[#9AA5A9] hover:text-[#2D3436]'
                    }`}
                    aria-label="북마크"
                  >
                    <Bookmark
                      className={`w-3.5 h-3.5 ${mission.bookmarked ? 'fill-[#FFB74D]' : ''}`}
                    />
                  </button>
                </div>
              </div>

              {/* 미션 제목 & 본문 */}
              <h3 className="text-[14px] font-extrabold text-[#2D3436] mb-1.5">
                {mission.title}
              </h3>
              <p className="text-[12.5px] text-[#4A5568] leading-relaxed">
                {mission.message}
              </p>

              {/* 완료 스탬프 오버레이 (수락 시) */}
              {mission.accepted && (
                <div className="absolute top-3 right-10 pointer-events-none select-none rotate-[-10deg]">
                  <div className="border-2 border-[#FF8A80] bg-[#FFF9F5]/95 text-[#FF8A80] rounded-full px-2.5 py-1 shadow-sm flex items-center gap-1">
                    <CheckCircle2 className="w-3.5 h-3.5" />
                    <span className="text-[10px] font-extrabold tracking-tight">다정함 스탬프</span>
                  </div>
                </div>
              )}

              {/* 하단 액션 버튼 */}
              <div className="mt-3.5 pt-2.5 border-t border-[#2D3436]/5">
                {!mission.accepted ? (
                  <button
                    type="button"
                    onClick={() => handleAcceptMission(mission)}
                    className="w-full py-2.5 px-4 rounded-xl bg-[#FFF0EE] hover:bg-[#FF8A80] text-[#E0665B] hover:text-white active:scale-[0.99] text-xs font-extrabold transition-all flex items-center justify-center gap-1.5 border border-[#FF8A80]/30"
                  >
                    오늘 해볼게요! 💛
                  </button>
                ) : (
                  <div className="flex items-center justify-between text-[11px] font-bold text-[#1E8449] bg-[#E8F8F0] px-3 py-2 rounded-xl">
                    <span className="flex items-center gap-1.5">
                      <CheckCircle2 className="w-4 h-4" />
                      오늘의 다정함 미션 수락 완료!
                    </span>
                    <span className="text-[10px] font-medium text-[#1E8449]/80">
                      {mission.acceptedAt}
                    </span>
                  </div>
                )}
              </div>
            </div>
          ))}
        </div>

        {/* 하단 미니 안내 */}
        <div className="bg-white border-t border-[#FF8A80]/15 px-5 py-3 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <img
              src={SAIBOT_AVATAR}
              alt="우리사이 봇"
              className="w-7 h-7 rounded-full object-cover border border-[#FF8A80]/30"
            />
            <p className="text-[11px] text-[#636E72]">
              매일 두 분께 어울리는 <strong className="text-[#2D3436]">다정함 팁</strong>이 도착해요
            </p>
          </div>
          <ChevronRight className="w-4 h-4 text-[#9AA5A9]" />
        </div>

        {/* iPhone 홈 인디케이터 */}
        <div className="bg-white pb-2 flex justify-center">
          <div className="w-28 h-1 rounded-full bg-[#2D3436]/20" />
        </div>
      </div>
    </div>
  );

  return (
    <div className="min-h-screen bg-[#FFF9F5] text-[#2D3436] font-sans selection:bg-[#FF8A80]/25">
      {/* 상단 듀얼 뷰 시뮬레이터 컨트롤 바 */}
      <header className="sticky top-0 z-30 bg-[#FFF9F5]/90 backdrop-blur-md border-b border-[#FF8A80]/20">
        <div className="max-w-6xl mx-auto px-4 py-3 flex flex-wrap items-center justify-between gap-3">
          {/* 브랜드 로고 */}
          <div className="flex items-center gap-2.5">
            <img
              src={SAIBOT_AVATAR}
              alt="우리사이 로고"
              className="w-10 h-10 rounded-2xl object-cover shadow-sm border border-[#FF8A80]/30"
            />
            <div>
              <div className="flex items-center gap-2">
                <h1 className="text-lg font-extrabold tracking-tight text-[#2D3436]">우리사이</h1>
                <span className="text-[10px] font-bold px-2 py-0.5 rounded-full bg-[#FF8A80]/15 text-[#E0665B]">
                  Dual-View 프로토타입
                </span>
              </div>
              <p className="text-xs text-[#636E72]">
                서운한 마음을 다정한 데일리 미션으로 번역하는 커플 코칭
              </p>
            </div>
          </div>

          {/* 듀얼 뷰 전환 컨트롤 */}
          <div className="flex items-center gap-2 flex-wrap">
            <div className="inline-flex bg-white p-1 rounded-2xl border border-[#FF8A80]/25 shadow-sm">
              <button
                type="button"
                onClick={() => handleSwitchView('dual')}
                className={`px-3 py-1.5 rounded-xl text-xs font-bold transition-all flex items-center gap-1.5 ${
                  viewMode === 'dual'
                    ? 'bg-[#2D3436] text-white shadow-sm'
                    : 'text-[#636E72] hover:text-[#2D3436]'
                }`}
              >
                <Columns2 className="w-3.5 h-3.5" />
                동시 보기
              </button>
              <button
                type="button"
                onClick={() => handleSwitchView('A')}
                className={`relative px-3 py-1.5 rounded-xl text-xs font-bold transition-all flex items-center gap-1.5 ${
                  viewMode === 'A'
                    ? 'bg-[#FF8A80] text-white shadow-sm'
                    : 'text-[#636E72] hover:text-[#2D3436]'
                }`}
              >
                <Smartphone className="w-3.5 h-3.5" />
                나의 화면(A)
                {aUnreadCount > 0 && (
                  <span className="w-4 h-4 rounded-full bg-[#2D3436] text-white text-[10px] flex items-center justify-center">
                    {aUnreadCount}
                  </span>
                )}
              </button>
              <button
                type="button"
                onClick={() => handleSwitchView('B')}
                className={`relative px-3 py-1.5 rounded-xl text-xs font-bold transition-all flex items-center gap-1.5 ${
                  viewMode === 'B'
                    ? 'bg-[#FFB74D] text-white shadow-sm'
                    : 'text-[#636E72] hover:text-[#2D3436]'
                }`}
              >
                <Smartphone className="w-3.5 h-3.5" />
                상대방 화면(B)
                {bUnreadCount > 0 && (
                  <span className="w-4 h-4 rounded-full bg-[#FF8A80] text-white text-[10px] flex items-center justify-center animate-bounce">
                    {bUnreadCount}
                  </span>
                )}
              </button>
            </div>

            {/* AI 엔진 설정 & 초기화 */}
            <button
              type="button"
              onClick={() => setShowApiModal(true)}
              className="p-2 rounded-xl bg-white border border-[#2D3436]/10 text-[#636E72] hover:text-[#2D3436] hover:border-[#FF8A80]/40 transition-colors shadow-sm"
              title="AI 변환 엔진 설정"
            >
              <Settings className="w-4 h-4" />
            </button>
            <button
              type="button"
              onClick={handleResetDemo}
              className="px-3 py-2 rounded-xl bg-white border border-[#2D3436]/10 text-xs font-semibold text-[#636E72] hover:text-[#FF8A80] hover:border-[#FF8A80]/40 transition-colors shadow-sm flex items-center gap-1"
            >
              <RotateCcw className="w-3.5 h-3.5" />
              초기화
            </button>
          </div>
        </div>
      </header>

      {/* 시그널 전달 라이브 상태 바 */}
      <div className="max-w-6xl mx-auto px-4 pt-4">
        <div
          className={`rounded-2xl px-4 py-2.5 border transition-all duration-500 flex flex-wrap items-center justify-between gap-2 ${
            signalPulse === 'AtoB'
              ? 'bg-[#FFF0EE] border-[#FF8A80] shadow-md'
              : signalPulse === 'BtoA'
              ? 'bg-[#FFF8E7] border-[#FFB74D] shadow-md'
              : 'bg-white/80 border-[#FF8A80]/15'
          }`}
        >
          <div className="flex items-center gap-2 text-xs">
            <Volume2
              className={`w-4 h-4 ${
                signalPulse ? 'text-[#FF8A80] animate-pulse' : 'text-[#9AA5A9]'
              }`}
            />
            {signalPulse === 'AtoB' ? (
              <span className="font-bold text-[#E0665B]">
                ✨ 사이봇이 A의 마음을 부드러운 데일리 미션으로 번역해 B의 피드에 자연스럽게 전달했어요!
              </span>
            ) : signalPulse === 'BtoA' ? (
              <span className="font-bold text-[#D48806]">
                💛 B가 데일리 미션을 수락했어요! A의 화면에 기분 좋은 알림과 함께 다정함 온도가 올랐습니다.
              </span>
            ) : (
              <span className="text-[#636E72]">
                <strong className="text-[#2D3436]">테스트 가이드:</strong> 왼쪽(A)에서 빠른 태그를 눌러 서운함을 입력하고 신호를 보낸 뒤, 오른쪽(B)에서 미션을 수락해 보세요.
              </span>
            )}
          </div>
          <span className="text-[11px] font-semibold text-[#9AA5A9]">
            엔진: {engineMode === 'gemini' && geminiApiKey ? 'Gemini API 연동' : '스마트 키워드 매칭'}
          </span>
        </div>
      </div>

      {/* 메인 듀얼/싱글 디바이스 영역 */}
      <main className="max-w-6xl mx-auto px-4 py-6 pb-12">
        {viewMode === 'dual' ? (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-8 items-start justify-items-center">
            {renderPhoneA()}
            {renderPhoneB()}
          </div>
        ) : viewMode === 'A' ? (
          <div className="flex justify-center">{renderPhoneA()}</div>
        ) : (
          <div className="flex justify-center">{renderPhoneB()}</div>
        )}
      </main>

      {/* AI 변환 엔진 설정 모달 */}
      {showApiModal && (
        <div className="fixed inset-0 z-50 bg-[#2D3436]/40 backdrop-blur-xs flex items-center justify-center p-4">
          <div className="bg-white rounded-3xl max-w-md w-full p-6 shadow-2xl border border-[#FF8A80]/20 space-y-4">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Wand2 className="w-5 h-5 text-[#FF8A80]" />
                <h3 className="text-base font-extrabold text-[#2D3436]">AI 넛지 변환 엔진 설정</h3>
              </div>
              <button
                type="button"
                onClick={() => setShowApiModal(false)}
                className="p-1.5 rounded-xl text-[#636E72] hover:bg-gray-100"
              >
                <X className="w-4 h-4" />
              </button>
            </div>

            <div className="space-y-2.5">
              <button
                type="button"
                onClick={() => {
                  setEngineMode('smart');
                  setApiNotice('즉시 동작하는 스마트 키워드 매칭 엔진을 사용합니다.');
                }}
                className={`w-full text-left p-3.5 rounded-2xl border transition-all ${
                  engineMode === 'smart'
                    ? 'border-[#FF8A80] bg-[#FFF9F5]'
                    : 'border-gray-200 hover:border-[#FF8A80]/40'
                }`}
              >
                <p className="text-xs font-extrabold text-[#2D3436]">
                  스마트 키워드 매칭 엔진 (기본 · API 키 불필요)
                </p>
                <p className="text-[11px] text-[#636E72] mt-1">
                  폰, 연락, 말투, 표현, 데이트 등 핵심 맥락을 분석해 자연스러운 다정함 미션 3종을 즉시 생성합니다.
                </p>
              </button>

              <div
                className={`p-3.5 rounded-2xl border transition-all ${
                  engineMode === 'gemini'
                    ? 'border-[#FF8A80] bg-[#FFF9F5]'
                    : 'border-gray-200'
                }`}
              >
                <button
                  type="button"
                  onClick={() => setEngineMode('gemini')}
                  className="w-full text-left"
                >
                  <p className="text-xs font-extrabold text-[#2D3436]">
                    Gemini API 직접 연동 (선택)
                  </p>
                  <p className="text-[11px] text-[#636E72] mt-1">
                    API 키를 입력하면 어떤 자유 문장도 실시간으로 공감 답장과 시치미 뚝 뗀 미션으로 번역합니다. (실패 시 스마트 엔진으로 자동 폴백)
                  </p>
                </button>

                {engineMode === 'gemini' && (
                  <div className="mt-3 space-y-2">
                    <input
                      type="password"
                      value={geminiApiKey}
                      onChange={(e) => setGeminiApiKey(e.target.value)}
                      placeholder="AIza... 형식의 Gemini API 키 입력"
                      className="w-full px-3 py-2 text-xs rounded-xl border border-[#FF8A80]/40 bg-white focus:outline-none focus:ring-2 focus:ring-[#FF8A80]/40"
                    />
                    <p className="text-[10px] text-[#9AA5A9]">
                      키는 브라우저 메모리에만 임시 유지되며 외부 서버에 저장되지 않습니다.
                    </p>
                  </div>
                )}
              </div>
            </div>

            {apiNotice && (
              <p className="text-[11px] font-semibold text-[#E0665B] bg-[#FFF0EE] px-3 py-2 rounded-xl">
                {apiNotice}
              </p>
            )}

            <div className="flex justify-end pt-1">
              <button
                type="button"
                onClick={() => {
                  setApiNotice('');
                  setShowApiModal(false);
                }}
                className="px-4 py-2 rounded-xl bg-[#FF8A80] hover:bg-[#F26D63] text-white text-xs font-bold shadow-sm"
              >
                적용하고 닫기
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}