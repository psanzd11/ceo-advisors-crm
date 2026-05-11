// ═══════════════════════════════════════════════════════════════════
// CEO Advisors CRM — TypeScript types (auto-generated)
// Source: Supabase project rtusnruywsmbbzejxooi
// Generated: 2026-05-10 (Fase 15.1)
//
// Estos types son SÓLO REFERENCIA para Claude al construir el adapter
// JavaScript en F15.3. El HTML actual es vanilla JS — no se importan
// en runtime. Sí pueden copiarse a un .d.ts si en algún momento se
// añade TypeScript al proyecto.
// ═══════════════════════════════════════════════════════════════════

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      activities: {
        Row: {
          client_id: string | null
          code: string
          company_id: string | null
          created_at: string | null
          created_by: string | null
          date: string | null
          deal_id: string | null
          done: boolean | null
          id: string
          notes: string | null
          title: string | null
          type: Database["public"]["Enums"]["activity_type"] | null
          updated_at: string | null
        }
        Insert: {
          client_id?: string | null
          code: string
          company_id?: string | null
          created_at?: string | null
          created_by?: string | null
          date?: string | null
          deal_id?: string | null
          done?: boolean | null
          id?: string
          notes?: string | null
          title?: string | null
          type?: Database["public"]["Enums"]["activity_type"] | null
          updated_at?: string | null
        }
        Relationships: [
          { foreignKeyName: "activities_client_id_fkey",  columns: ["client_id"],  referencedRelation: "clients",     referencedColumns: ["id"] },
          { foreignKeyName: "activities_company_id_fkey", columns: ["company_id"], referencedRelation: "companies",   referencedColumns: ["id"] },
          { foreignKeyName: "activities_created_by_fkey", columns: ["created_by"], referencedRelation: "consultants", referencedColumns: ["id"] },
          { foreignKeyName: "activities_deal_id_fkey",    columns: ["deal_id"],    referencedRelation: "deals",       referencedColumns: ["id"] }
        ]
      }
      activity_log: {
        Row: {
          action: string
          entity: string | null
          entity_id: string | null
          id: string
          metadata: Json | null
          ts: string | null
          user_id: string | null
        }
        Relationships: []
      }
      clients: {
        Row: {
          city: string | null
          code: string
          country: string | null
          created_at: string | null
          email: string | null
          id: string
          name: string
          net_worth: number | null
          notes: string | null
          phone: string | null
          source: string | null
          tier: Database["public"]["Enums"]["client_tier"] | null
          updated_at: string | null
        }
        Relationships: []
      }
      companies: {
        Row: {
          client_ids: Json | null   // array de UUIDs de clients
          code: string
          country: string | null
          created_at: string | null
          employees: number | null
          id: string
          industry: string | null
          name: string
          net_worth: number | null
          notes: string | null
          updated_at: string | null
          website: string | null
        }
        Relationships: []
      }
      consultants: {
        Row: {
          auth_user_id: string | null
          bio: string | null
          code: string
          created_at: string | null
          email: string | null
          id: string
          is_admin: boolean | null
          is_ceo: boolean | null
          name: string
          region: string | null
          role: string | null
          updated_at: string | null
        }
        Relationships: []
      }
      deals: {
        Row: {
          amount: number | null
          client_id: string | null
          close_date: string | null
          code: string
          company_id: string | null
          created_at: string | null
          id: string
          notes: string | null
          splits: Json | null   // [{u: consultant_id, pct: number}]
          stage: Database["public"]["Enums"]["deal_stage"] | null
          title: string
          type: Database["public"]["Enums"]["deal_type"] | null
          updated_at: string | null
        }
        Relationships: [
          { foreignKeyName: "deals_client_id_fkey",  columns: ["client_id"],  referencedRelation: "clients",   referencedColumns: ["id"] },
          { foreignKeyName: "deals_company_id_fkey", columns: ["company_id"], referencedRelation: "companies", referencedColumns: ["id"] }
        ]
      }
      pupilos: {
        Row: {
          code: string
          consultant_id: string | null
          created_at: string | null
          docs: Json | null
          email: string | null
          end_date: string | null
          id: string
          left_company: string | null
          left_role: string | null
          mentor: string | null
          name: string
          notes: string | null
          program: string | null
          region: string | null
          start_date: string | null
          university: string | null
          updated_at: string | null
        }
        Relationships: [
          { foreignKeyName: "pupilos_consultant_id_fkey", columns: ["consultant_id"], referencedRelation: "consultants", referencedColumns: ["id"] }
        ]
      }
    }
    Functions: {
      is_admin: { Args: never; Returns: boolean }
      my_consultant_id: { Args: never; Returns: string }
    }
    Enums: {
      activity_type: "meeting" | "call" | "email" | "note" | "task" | "other"
      client_tier:   "A" | "B" | "C" | "D"
      deal_stage:    "lead" | "contact" | "proposal" | "negotiation" | "won" | "lost" | "on-hold"
      deal_type:     "mandate" | "retainer" | "equity" | "board" | "advisor" | "other"
    }
  }
}

export const Constants = {
  public: {
    Enums: {
      activity_type: ["meeting", "call", "email", "note", "task", "other"],
      client_tier:   ["A", "B", "C", "D"],
      deal_stage:    ["lead", "contact", "proposal", "negotiation", "won", "lost", "on-hold"],
      deal_type:     ["mandate", "retainer", "equity", "board", "advisor", "other"],
    },
  },
} as const
