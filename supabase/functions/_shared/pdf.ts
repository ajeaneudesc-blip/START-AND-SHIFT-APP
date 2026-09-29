import { PDFDocument, type PDFFont, type PDFPage, rgb, StandardFonts } from "npm:pdf-lib@1.17.1";
import type { PlanContent } from "./plan-schema.ts";

// Charte Start And Shift
const BLUE = rgb(0x09 / 255, 0x5c / 255, 0xff / 255);   // Bleu Start
const ORANGE = rgb(0xff / 255, 0x91 / 255, 0x5e / 255); // Orange Shift
const INK = rgb(0x29 / 255, 0x29 / 255, 0x29 / 255);    // Encre
const MUTED = rgb(0.45, 0.45, 0.45);
const LIGHT = rgb(0.96, 0.96, 0.96);

const A4: [number, number] = [595.28, 841.89];
const M = 50; // marge

// Les polices standard PDF ne couvrent que WinAnsi : on remplace les caractères hors jeu.
const REPLACE: Record<string, string> = {
  "\u202f": " ", "\u00a0": " ", "\u2009": " ", "→": "->", "←": "<-", "✓": "v", "✔": "v",
  "\u2011": "-", "−": "-", "•": "•",
};

class Writer {
  doc!: PDFDocument;
  page!: PDFPage;
  regular!: PDFFont;
  bold!: PDFFont;
  y = 0;
  private cache = new Map<string, boolean>();

  static async create(): Promise<Writer> {
    const w = new Writer();
    w.doc = await PDFDocument.create();
    w.regular = await w.doc.embedFont(StandardFonts.Helvetica);
    w.bold = await w.doc.embedFont(StandardFonts.HelveticaBold);
    w.newPage();
    return w;
  }

  clean(text: string): string {
    let out = "";
    for (const ch of text.replace(/\r/g, "")) {
      const c = REPLACE[ch] ?? ch;
      if (c === "\n") {
        out += c;
        continue;
      }
      let ok = this.cache.get(c);
      if (ok === undefined) {
        try {
          this.regular.encodeText(c);
          ok = true;
        } catch {
          ok = false;
        }
        this.cache.set(c, ok);
      }
      out += ok ? c : "";
    }
    return out;
  }

  newPage() {
    this.page = this.doc.addPage(A4);
    this.y = A4[1] - M;
  }

  ensure(h: number) {
    if (this.y - h < M + 20) this.newPage();
  }

  wrap(text: string, font: PDFFont, size: number, width: number): string[] {
    const lines: string[] = [];
    for (const para of this.clean(text).split("\n")) {
      let line = "";
      for (const word of para.split(/\s+/).filter(Boolean)) {
        const test = line ? `${line} ${word}` : word;
        if (font.widthOfTextAtSize(test, size) > width && line) {
          lines.push(line);
          line = word;
        } else {
          line = test;
        }
      }
      lines.push(line);
    }
    return lines;
  }

  text(text: string, opts: { size?: number; bold?: boolean; color?: ReturnType<typeof rgb>; indent?: number; gap?: number } = {}) {
    const size = opts.size ?? 10.5;
    const font = opts.bold ? this.bold : this.regular;
    const x = M + (opts.indent ?? 0);
    const lh = size * 1.4;
    for (const line of this.wrap(text, font, size, A4[0] - x - M)) {
      this.ensure(lh);
      this.page.drawText(line, { x, y: this.y - size, size, font, color: opts.color ?? INK });
      this.y -= lh;
    }
    this.y -= opts.gap ?? 4;
  }

  bullets(items: string[], marker = "•", indent = 10) {
    for (const item of items) {
      const size = 10.5;
      const lines = this.wrap(item, this.regular, size, A4[0] - M * 2 - indent - 12);
      lines.forEach((line, i) => {
        this.ensure(size * 1.4);
        if (i === 0) this.page.drawText(this.clean(marker), { x: M + indent, y: this.y - size, size, font: this.bold, color: ORANGE });
        this.page.drawText(line, { x: M + indent + 12, y: this.y - size, size, font: this.regular, color: INK });
        this.y -= size * 1.4;
      });
    }
    this.y -= 4;
  }

  heading(text: string, color = BLUE) {
    this.ensure(40);
    this.y -= 8;
    this.page.drawRectangle({ x: M, y: this.y - 20, width: 4, height: 18, color: ORANGE });
    this.page.drawText(this.clean(text), { x: M + 12, y: this.y - 16, size: 15, font: this.bold, color });
    this.y -= 30;
  }

  label(text: string) {
    this.ensure(20);
    this.page.drawText(this.clean(text.toUpperCase()), { x: M, y: this.y - 8, size: 8, font: this.bold, color: MUTED });
    this.y -= 14;
  }

  footer(left: string) {
    const pages = this.doc.getPages();
    pages.forEach((p, i) => {
      p.drawText(this.clean(left), { x: M, y: 25, size: 8, font: this.regular, color: MUTED });
      const n = `${i + 1} / ${pages.length}`;
      p.drawText(n, { x: A4[0] - M - this.regular.widthOfTextAtSize(n, 8), y: 25, size: 8, font: this.regular, color: MUTED });
    });
  }
}

const frDate = (d: Date) =>
  new Intl.DateTimeFormat("fr-FR", { day: "numeric", month: "long", year: "numeric", timeZone: "Africa/Lome" }).format(d);

export const fcfa = (n: number) => `${new Intl.NumberFormat("fr-FR").format(n).replace(/\u202f|\u00a0/g, " ")} F`;

export async function renderPlanPdf(plan: PlanContent, meta: { business: string; date: Date }): Promise<Uint8Array> {
  const w = await Writer.create();

  // Couverture (bandeau)
  w.page.drawRectangle({ x: 0, y: A4[1] - 170, width: A4[0], height: 170, color: BLUE });
  w.page.drawText("START AND SHIFT", { x: M, y: A4[1] - 55, size: 10, font: w.bold, color: rgb(1, 1, 1) });
  w.page.drawText(w.clean("Stratégie de communication"), { x: M, y: A4[1] - 95, size: 24, font: w.bold, color: rgb(1, 1, 1) });
  w.page.drawText(w.clean(meta.business).slice(0, 60), { x: M, y: A4[1] - 125, size: 14, font: w.regular, color: rgb(1, 1, 1) });
  w.page.drawText(w.clean(`Préparé le ${frDate(meta.date)}`), { x: M, y: A4[1] - 150, size: 9, font: w.regular, color: rgb(1, 1, 1) });
  w.y = A4[1] - 200;

  w.text(plan.headline, { size: 16, bold: true, color: INK, gap: 8 });
  w.text(plan.summary, { gap: 10 });
  w.page.drawRectangle({ x: M, y: w.y - 34, width: A4[0] - 2 * M, height: 34, color: LIGHT });
  w.page.drawText(w.clean("À faire aujourd'hui"), { x: M + 10, y: w.y - 14, size: 8, font: w.bold, color: ORANGE });
  w.page.drawText(w.wrap(plan.next_step, w.regular, 10, A4[0] - 2 * M - 20)[0] ?? "", { x: M + 10, y: w.y - 27, size: 10, font: w.regular, color: INK });
  w.y -= 44;

  plan.sections.forEach((s, i) => {
    w.heading(`${i + 1}. ${s.title}`);
    w.label("En clair");
    w.text(s.clair, { gap: 6 });
    w.bullets(s.points);
    w.label("Détail pro");
    w.text(s.detail_pro, { size: 10, gap: 6 });
    w.label("Cette semaine");
    w.bullets(s.actions, "->");
  });

  w.heading("Votre calendrier sur 4 semaines");
  for (const week of plan.weekly_plan) {
    w.text(`Semaine ${week.week} — ${week.focus}`, { bold: true, gap: 2 });
    w.bullets(week.posts.map((p) => `${p.day} · ${p.channel} · ${p.format} : ${p.idea}`));
  }

  w.heading("Les visuels à commander en priorité");
  for (const v of plan.recommended_visuals) {
    w.text(v.title, { bold: true, gap: 1 });
    w.text(v.brief, { gap: 1 });
    w.text(v.why, { size: 9.5, color: MUTED, gap: 6 });
  }

  w.heading("Comment mesurer vos progrès");
  w.bullets(plan.kpis.map((k) => `${k.name} — objectif : ${k.target}. Comment : ${k.how_to_measure}`));

  w.footer(`Start And Shift · ${meta.business}`);
  return await w.doc.save();
}

export interface InvoiceData {
  number: string;
  issued_at: string;
  label: string;
  amount_fcfa: number;
  method: string | null;
  customer: { name?: string | null; email?: string | null; phone?: string | null; brand?: string | null };
  seller: { name: string; address: string; legal: string };
  refunded?: boolean;
}

export async function renderInvoicePdf(inv: InvoiceData): Promise<Uint8Array> {
  const w = await Writer.create();
  const right = (text: string, y: number, size: number, bold = false) => {
    const font = bold ? w.bold : w.regular;
    const t = w.clean(text);
    w.page.drawText(t, { x: A4[0] - M - font.widthOfTextAtSize(t, size), y, size, font, color: INK });
  };

  w.page.drawRectangle({ x: 0, y: A4[1] - 8, width: A4[0], height: 8, color: BLUE });
  w.page.drawText(w.clean(inv.seller.name), { x: M, y: A4[1] - 60, size: 18, font: w.bold, color: BLUE });
  w.page.drawText(w.clean(inv.seller.address), { x: M, y: A4[1] - 78, size: 9, font: w.regular, color: MUTED });
  right("FACTURE", A4[1] - 60, 18, true);
  right(`N° ${inv.number}`, A4[1] - 78, 10);
  right(`Date : ${frDate(new Date(inv.issued_at))}`, A4[1] - 92, 10);

  w.y = A4[1] - 130;
  w.label("Facturé à");
  const c = inv.customer;
  for (const line of [c.name, c.brand, c.phone, c.email].filter(Boolean) as string[]) w.text(line, { gap: 0 });
  w.y -= 20;

  // Tableau
  const top = w.y;
  w.page.drawRectangle({ x: M, y: top - 24, width: A4[0] - 2 * M, height: 24, color: LIGHT });
  w.page.drawText("Description", { x: M + 10, y: top - 16, size: 9, font: w.bold, color: INK });
  right("Montant", top - 16, 9, true);
  const lines = w.wrap(inv.label, w.regular, 10.5, 360);
  lines.forEach((l, i) => w.page.drawText(l, { x: M + 10, y: top - 44 - i * 14, size: 10.5, font: w.regular, color: INK }));
  right(fcfa(inv.amount_fcfa), top - 44, 10.5);
  const bottom = top - 44 - lines.length * 14 - 10;
  w.page.drawLine({ start: { x: M, y: bottom }, end: { x: A4[0] - M, y: bottom }, thickness: 0.5, color: MUTED });
  right(`Total : ${fcfa(inv.amount_fcfa)}`, bottom - 22, 13, true);
  w.page.drawText(w.clean(inv.refunded ? "Remboursée" : `Payée${inv.method ? ` · ${inv.method}` : ""}`),
    { x: M, y: bottom - 22, size: 10, font: w.bold, color: inv.refunded ? ORANGE : BLUE });

  w.y = bottom - 60;
  w.text("Montants en francs CFA (XOF).", { size: 8.5, color: MUTED, gap: 2 });
  w.text("Garantie : premier mois d'abonnement remboursé si vous n'êtes pas satisfait, après usage des modifications incluses.", { size: 8.5, color: MUTED, gap: 2 });
  if (inv.seller.legal) w.text(inv.seller.legal, { size: 8.5, color: MUTED });

  w.footer(`${inv.seller.name} · Facture ${inv.number}`);
  return await w.doc.save();
}
