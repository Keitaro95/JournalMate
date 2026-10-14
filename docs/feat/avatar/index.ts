// アバター判定 Worker
// iPhone アプリ → (JPEG の data URL) → この Worker → Clef → 正規化した JSON をアプリへ返す
//
// 返す JSON:
// { "answers": { "faceShape": { "value": "round", "confidence": 0.48 }, ... }, "ms": 1215 }
// はい/いいえの質問は value が "yes" / "no" になります。

export interface Env {
  AI: Ai;
  APP_TOKEN?: string; // 任意: `wrangler secret put APP_TOKEN` で設定すると x-app-token ヘッダーを必須にする
}

type Question =
  | { type: "noul"; instructions: string }
  | { type: "choice"; instructions: string; criteria: Record<string, string> };

const yesNo = (instructions: string): Question => ({ type: "noul", instructions });
const choice = (instructions: string, criteria: Record<string, string>): Question => ({
  type: "choice",
  instructions,
  criteria,
});

// 質問 id と選択肢 id は、Swift 側 AvatarConfig のプロパティ名 / enum の rawValue と一致させること
const QUESTIONS: Record<string, Question> = {
  // 輪郭
  faceShape: choice("What is the overall shape of the person's face?", {
    round: "Round face, width and height similar, soft jaw",
    oval: "Oval / egg-shaped face",
    long: "Long, narrow face",
    square: "Square face with an angular jaw",
  }),
  skinTone: choice("What is the person's skin tone?", {
    fair: "Fair / light",
    medium: "Medium",
    tan: "Tan / olive",
    dark: "Dark brown",
  }),
  // 服
  clothColor: choice("What is the main color of the clothing on the upper body?", {
    gray: "Gray",
    white: "White",
    black: "Black",
    navy: "Navy / dark blue",
    blue: "Blue",
    red: "Red",
    green: "Green",
    yellow: "Yellow",
    pink: "Pink",
    brown: "Brown / beige",
  }),
  // 髪
  hairLength: choice("How long is the person's hair?", {
    none: "Bald or shaved head",
    short: "Short, above the ears",
    medium: "Medium, between ears and shoulders",
    long: "Long, reaching the shoulders or below",
  }),
  hairColor: choice("What is the person's hair color?", {
    black: "Black",
    darkBrown: "Dark brown",
    brown: "Brown / light brown",
    blonde: "Blonde",
    red: "Red / orange",
    gray: "Gray",
    white: "White",
  }),
  hairTexture: choice("What is the hair texture?", {
    straight: "Straight",
    wavy: "Wavy",
    curly: "Curly",
  }),
  hairVolume: choice("How much volume does the hair have?", {
    low: "Flat, little volume",
    normal: "Average volume",
    high: "A lot of volume",
  }),
  // 髪型
  bangs: choice("How are the bangs / fringe styled?", {
    none: "No bangs, forehead fully visible",
    down: "Bangs hanging straight down over the forehead",
    side: "Bangs swept to one side",
  }),
  parting: choice("Where is the hair parted, as seen in the image?", {
    none: "No visible parting",
    left: "Parted on the left side of the image",
    center: "Parted in the center",
    right: "Parted on the right side of the image",
  }),
  spiky: yesNo("Is the hair styled standing up or spiky?"),
  hairTie: choice("How is the hair tied?", {
    down: "Not tied, worn down",
    ponytail: "Single ponytail",
    twinTails: "Two tails / pigtails",
    bun: "Bun",
  }),
  earsHidden: yesNo("Are the ears covered by hair?"),
  // 眉
  browThickness: choice("How thick are the eyebrows?", {
    thin: "Thin",
    normal: "Average",
    thick: "Thick",
  }),
  browShape: choice("What is the shape of the eyebrows?", {
    straight: "Straight",
    arched: "Arched / curved",
    angled: "Angled upward toward the outer end",
    down: "Sloping downward toward the outer end",
  }),
  // 目
  singleLid: yesNo("Do the eyes have single eyelids (monolids, no visible crease)?"),
  eyeSize: choice("How large are the eyes?", {
    small: "Small / narrow",
    normal: "Average",
    large: "Large",
  }),
  eyeTilt: choice("How are the outer corners of the eyes angled?", {
    droopy: "Outer corners lower than inner corners",
    normal: "Level",
    upturned: "Outer corners higher than inner corners",
  }),
  eyeColor: choice("What is the eye color?", {
    black: "Black",
    darkBrown: "Dark brown",
    brown: "Light brown / hazel",
    blue: "Blue",
    green: "Green",
    gray: "Gray",
  }),
  longLashes: yesNo("Does the person have long, prominent eyelashes?"),
  // 鼻と口
  noseSize: choice("How large is the nose?", {
    small: "Small",
    normal: "Average",
    large: "Large",
  }),
  lipThickness: choice("How thick are the lips?", {
    thin: "Thin",
    normal: "Average",
    thick: "Full",
  }),
  smiling: yesNo("Is the person smiling?"),
  mouthOpen: yesNo("Is the person's mouth open?"),
  // ほっぺ
  blush: yesNo("Are the cheeks noticeably red or rosy?"),
  freckles: yesNo("Does the person have freckles?"),
  // ひげ
  mustache: choice("Does the person have a mustache (hair above the upper lip)?", {
    none: "No mustache",
    thin: "Thin or light mustache",
    thick: "Thick mustache",
  }),
  beard: choice("Does the person have a beard on the chin or jaw?", {
    none: "Clean-shaven chin",
    stubble: "Stubble",
    full: "Full beard",
  }),
  longSideburns: yesNo("Does the person have long sideburns?"),
  // 小物
  glasses: choice("Is the person wearing glasses?", {
    none: "No glasses",
    square: "Glasses with square or rectangular frames",
    round: "Glasses with round frames",
    sunglasses: "Sunglasses",
  }),
  earrings: yesNo("Is the person wearing earrings or ear piercings?"),
  hat: choice("Is the person wearing something on their head?", {
    none: "Nothing",
    cap: "Baseball cap",
    beanie: "Knit beanie",
    hat: "Hat with a brim all around",
  }),
};

type NormalizedAnswer = { value: string; confidence: number };

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "POST") {
      return json({ error: "POST only" }, 405);
    }
    if (env.APP_TOKEN && request.headers.get("x-app-token") !== env.APP_TOKEN) {
      return json({ error: "unauthorized" }, 401);
    }

    let image: unknown;
    try {
      ({ image } = (await request.json()) as { image?: unknown });
    } catch {
      return json({ error: "invalid JSON" }, 400);
    }
    if (typeof image !== "string" || !/^data:image\/(jpeg|png|webp);base64,/i.test(image)) {
      return json({ error: "image must be a base64 data URL (jpeg/png/webp)" }, 400);
    }
    // base64 で約 5.5MB ≒ デコード後 4MiB（Clef の 1 枚あたりの上限）
    if (image.length > 5_500_000) {
      return json({ error: "image too large" }, 413);
    }

    const started = Date.now();
    let result: any;
    try {
      result = await (env.AI as any).run("@cf/cloudflare/clef", {
        model: "clef", // 速度優先なら "@cf/cloudflare/clef-flash" と "clef-flash"
        state:
          "The attached image is a front-facing selfie of one person. Answer each question about that person's visible appearance.",
        questions: QUESTIONS,
        images: [image],
      });
    } catch (e) {
      return json({ error: "clef failed", detail: String(e) }, 502);
    }

    const answers: Record<string, NormalizedAnswer> = {};
    for (const [id, a] of Object.entries<any>(result?.answers ?? {})) {
      if (a?.type === "noul") {
        const p = Number(a.noul);
        answers[id] = { value: p >= 0.5 ? "yes" : "no", confidence: Math.max(p, 1 - p) };
      } else if (a?.type === "choice") {
        // 画面に出す % は「選ばれた選択肢の確率」
        const p = a.probabilities?.[a.choice];
        answers[id] = { value: a.choice, confidence: typeof p === "number" ? p : a.confidence };
      }
    }

    return json({ answers, ms: Date.now() - started });
  },
} satisfies ExportedHandler<Env>;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}
