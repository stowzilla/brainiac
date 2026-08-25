# Supplier Commerce Foundation & Amazon Business Capability Map

## Overview

This document defines the foundational concepts, domain model, and capability map for supplier commerce within the Stowzilla Partners ecosystem. It establishes the vocabulary, boundaries, and integration surface for procuring supplies, managing supplier relationships, and leveraging Amazon Business as a procurement channel.

## Domain Context

The Partners app manages inventory, supply chain operations, and fulfillment for the Stowzilla storage and marketplace business. Supplier commerce extends this by formalizing how the business procures materials, tracks costs, and maintains supplier relationships — with Amazon Business as the primary automated procurement channel.

---

## 1. Supplier Commerce Domain Model

### Core Entities

| Entity | Description | Identity |
|--------|-------------|----------|
| **Supplier** | An external entity that provides goods or services | `supplier_id` (organization-scoped) |
| **SupplierCatalogItem** | A purchasable item from a supplier's catalog | `catalog_item_id` + `supplier_id` |
| **PurchaseOrder** | A formal request to a supplier for goods | `purchase_order_id` (extends existing PO from #1247) |
| **PurchaseOrderLine** | A line item on a PO referencing a catalog item | `line_id` + `purchase_order_id` |
| **SupplierPriceRecord** | A point-in-time price observation for a catalog item | `price_record_id` |
| **ProcurementRule** | An automated rule governing when/how to reorder | `rule_id` |
| **SupplierAccount** | Credentials and configuration for a supplier channel | `account_id` + `supplier_id` |

### Relationships

```
Organization
 └── Supplier (many)
      ├── SupplierAccount (one per channel, e.g. Amazon Business)
      ├── SupplierCatalogItem (many)
      │    ├── SupplierPriceRecord (many, time-series)
      │    └── PurchaseOrderLine (many, via PO)
      └── PurchaseOrder (many)
           └── PurchaseOrderLine (many)
                └── InboundLine (links to #1247 supply planning)

ProcurementRule
 └── references: SupplierCatalogItem + StockLine (inventory identity)
```

### Key Principles

1. **Supplier is channel-agnostic** — A supplier may be Amazon Business, a local vendor, or a direct manufacturer. The domain model doesn't assume any single channel.
2. **Price is a time-series observation** — Prices change. Every observed price is recorded with timestamp, source, and context. Current price is the most recent observation, not a mutable field.
3. **PO lifecycle integrates with existing supply planning** — Purchase orders from #1247 gain supplier identity and cost tracking without breaking the existing commitment/inbound/receipt flow.
4. **Procurement rules are declarative** — Rules express intent (reorder when available < threshold), not imperative workflows. Evaluation is deterministic and auditable.

---

## 2. Supplier Commerce Capabilities

### Capability Map

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SUPPLIER COMMERCE                                  │
├─────────────────────┬───────────────────────┬───────────────────────┤
│  Supplier Mgmt      │  Procurement          │  Cost Intelligence    │
├─────────────────────┼───────────────────────┼───────────────────────┤
│ • Supplier registry │ • Purchase order      │ • Price tracking      │
│ • Account linking   │   creation            │ • Cost history        │
│ • Catalog sync      │ • Approval workflows  │ • Price comparison    │
│ • Contact mgmt     │ • Order placement     │ • Spend analytics     │
│                     │ • Receipt & matching  │ • Budget monitoring   │
├─────────────────────┼───────────────────────┼───────────────────────┤
│  Automation         │  Integration          │  Compliance           │
├─────────────────────┼───────────────────────┼───────────────────────┤
│ • Reorder rules     │ • Channel adapters    │ • Audit trail         │
│ • Threshold alerts  │ • Catalog import      │ • Approval policies   │
│ • Auto-PO creation  │ • Order submission    │ • Spend limits        │
│ • Schedule-based    │ • Status polling      │ • Tax documentation   │
│   replenishment     │ • Webhook receipt     │ • Receipt matching    │
└─────────────────────┴───────────────────────┴───────────────────────┘
```

### Capability Definitions

#### Supplier Management
- **Supplier Registry** — CRUD for supplier records with organization scoping. Includes business name, type (distributor, manufacturer, marketplace), and status.
- **Account Linking** — Connect supplier accounts (Amazon Business credentials, vendor portals) to enable automated operations.
- **Catalog Sync** — Import and maintain a local mirror of supplier product catalogs. Handles ASIN mapping for Amazon, SKU mapping for others.
- **Contact Management** — Track supplier contacts, terms, lead times, and relationship metadata.

#### Procurement
- **Purchase Order Creation** — Generate POs from manual requests or automated rules. Links to existing #1247 PO/commitment infrastructure.
- **Approval Workflows** — Configurable approval thresholds (e.g., orders > $500 require manager approval). Phase one: single-level approval.
- **Order Placement** — Submit approved POs to the supplier channel (Amazon Business API, email, vendor portal).
- **Receipt & Matching** — Match received goods against PO lines, record discrepancies. Ties into #1246 ledger receipt flow.

#### Cost Intelligence
- **Price Tracking** — Record every price observation with source, timestamp, and context (list price, negotiated price, promotional price).
- **Cost History** — Time-series view of costs per item across suppliers. Supports cost-of-goods-sold calculations.
- **Price Comparison** — Compare current prices across suppliers for the same item. Identifies cost-saving opportunities.
- **Spend Analytics** — Aggregate spend by supplier, category, time period. Supports budgeting and forecasting.
- **Budget Monitoring** — Track actual vs. planned spend with configurable alert thresholds.

#### Automation
- **Reorder Rules** — Declarative rules: "When available_now for item X drops below Y, create a PO for Z units from supplier S."
- **Threshold Alerts** — Notify operators when inventory levels, prices, or spend cross configured thresholds.
- **Auto-PO Creation** — Rules can automatically create draft POs (still require approval unless configured otherwise).
- **Schedule-Based Replenishment** — Recurring orders on a fixed schedule (weekly supply runs, monthly bulk orders).

#### Integration
- **Channel Adapters** — Pluggable adapter pattern for each supplier channel. Amazon Business is the first adapter.
- **Catalog Import** — Parse supplier catalogs (CSV, API response, PDF) into normalized SupplierCatalogItem records.
- **Order Submission** — Adapter-specific logic to place orders (API call, email generation, portal automation).
- **Status Polling** — Check order/shipment status from supplier systems. Update PO/inbound line status.
- **Webhook Receipt** — Receive push notifications from supplier systems (shipment updates, price changes).

#### Compliance
- **Audit Trail** — Immutable log of all procurement actions (who approved what, when, why).
- **Approval Policies** — Configurable rules governing who can approve what spend levels.
- **Spend Limits** — Per-user, per-department, per-supplier spending caps.
- **Tax Documentation** — Track tax-exempt status, collect W-9s, manage resale certificates.
- **Receipt Matching** — Three-way match (PO, receipt, invoice) for financial reconciliation.

---

## 3. Amazon Business Capability Map

Amazon Business is the primary automated procurement channel. This section maps Amazon Business platform capabilities to our domain.

### Amazon Business Platform Capabilities

| Amazon Capability | Our Integration | Priority | Notes |
|-------------------|-----------------|----------|-------|
| **Business account** | SupplierAccount | P0 | Foundation — required for all other capabilities |
| **Product search & catalog** | Catalog sync (ASIN-based) | P0 | Core data source for SupplierCatalogItem |
| **Business pricing** | SupplierPriceRecord | P0 | Business-only discounts, quantity pricing |
| **Purchasing** | PO → Order placement | P0 | Submit orders via Amazon Business |
| **Order tracking** | Status polling / webhooks | P1 | Track shipment and delivery status |
| **Approval workflows** | Approval policies | P1 | Amazon's built-in approval chains |
| **Spend visibility** | Spend analytics | P1 | Amazon's spending reports and dashboards |
| **Tax exemption** | Tax documentation | P1 | Apply tax-exempt status to purchases |
| **Multi-user accounts** | Account linking | P1 | Multiple buyers under one business account |
| **Amazon Business Analytics** | Cost intelligence feed | P2 | Historical pricing and spend data |
| **Punchout catalog** | Catalog integration | P2 | cXML/OCI catalog browsing |
| **Pay by Invoice** | Payment terms | P2 | Net-30/60 payment terms |
| **Guided buying** | Procurement rules | P2 | Preferred supplier/item policies |
| **Quantity discounts** | Price tier tracking | P2 | Volume-based pricing tiers |
| **Amazon Business Prime** | Shipping optimization | P3 | Free shipping, faster delivery |
| **Recurring deliveries** | Schedule replenishment | P3 | Subscribe & Save for business |
| **Integration APIs** | Channel adapter | P0 | API access for automation |

### Amazon Business Integration Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   Partners App                           │
│                                                         │
│  ┌──────────────┐    ┌──────────────────────────────┐  │
│  │ Procurement  │───▶│ Amazon Business Adapter       │  │
│  │ Service      │    │                              │  │
│  └──────────────┘    │  • Catalog sync (ASIN→Item) │  │
│         │            │  • Price polling             │  │
│         ▼            │  • Order submission          │  │
│  ┌──────────────┐    │  • Status tracking          │  │
│  │ Supplier     │    │  • Spend data import        │  │
│  │ Registry     │    └──────────┬───────────────────┘  │
│  └──────────────┘               │                      │
│                                 ▼                      │
│                    ┌────────────────────────┐           │
│                    │ Amazon Business APIs   │           │
│                    │ (Product Advertising,  │           │
│                    │  Purchasing, Analytics)│           │
│                    └────────────────────────┘           │
└─────────────────────────────────────────────────────────┘
```

### Integration Approach

#### Phase 1: Manual with Price Tracking (P0)
- Register Amazon Business as a supplier
- Link Amazon Business account credentials
- Import frequently-purchased items by ASIN into catalog
- Record prices manually or via periodic API polling
- Create POs that reference Amazon catalog items
- Track cost history per item

#### Phase 2: Semi-Automated Procurement (P1)
- Automated price polling on watched ASINs
- Price-change alerts (item went up/down by X%)
- Draft PO creation from reorder rules
- Order status synchronization
- Spend reporting integration

#### Phase 3: Full Automation (P2-P3)
- Punchout catalog browsing from Partners UI
- Automatic order placement for approved POs
- Recurring delivery scheduling
- Multi-supplier price comparison with auto-routing
- Budget enforcement and guided buying policies

### Amazon Business API Surface

| API | Purpose | Auth | Rate Limits |
|-----|---------|------|-------------|
| **Product Advertising API (PA-API 5.0)** | Search products, get pricing, item details | Access key + secret | 1 req/sec (scales with revenue) |
| **Amazon Business Purchasing API** | Place orders, track status | OAuth 2.0 | Varies by account tier |
| **Amazon Business Analytics API** | Spend reports, purchase history | OAuth 2.0 | Daily batch |
| **Catalog API (SP-API)** | Detailed product data, variations | OAuth 2.0 + IAM | Varies |

### Data Mapping: Amazon → Domain

| Amazon Concept | Domain Entity | Mapping Logic |
|----------------|---------------|---------------|
| ASIN | SupplierCatalogItem.external_id | 1:1, stable identifier |
| Business Price | SupplierPriceRecord | Polled periodically, stored as time-series |
| Quantity Discount Tier | SupplierPriceRecord (with quantity context) | Each tier = separate price record |
| Order | PurchaseOrder | Created in our system, submitted to Amazon |
| Order Line | PurchaseOrderLine | Maps to ASIN-based catalog item |
| Shipment | InboundLine (from #1247) | Links PO line to supply planning |
| Delivery | Ledger receipt event (from #1246) | Physical receipt triggers inventory update |

---

## 4. Integration with Existing Supply Chain

### How Supplier Commerce Connects to the Control Tower Epic

```
                    Existing (#1246-#1252)              New (Supplier Commerce)
                    ─────────────────────              ────────────────────────
                    
Inventory Truth ──▶ InventoryLedgerEntry               
                         │                             
                         ▼                             
Balances ──────────▶ InventoryBalance ◀──────────────── Cost-per-unit attribution
                         │                             
                         ▼                             
Planning ──────────▶ Commitments/PO/Inbound ◀───────── PO from supplier (new)
                         │                                    │
                         ▼                                    ▼
Projections ───────▶ ProjectedAvailability              SupplierPriceRecord
                         │                             (cost projection)
                         ▼                             
Exceptions ────────▶ SupplyChainExceptions ◀──────────── Reorder rules trigger
                         │                             
                         ▼                             
Operator View ─────▶ Control Tower (#1251) ◀──────────── Supplier/cost context
```

### Touchpoints with Existing Cards

| Existing Component | Integration Point | Direction |
|--------------------|-------------------|-----------|
| #1246 Inventory Ledger | Receipt from supplier creates ledger entry | Supplier → Ledger |
| #1247 Supply Planning | PO creation links to supplier + cost data | Supplier → Planning |
| #1247 InboundLine | Supplier shipment maps to inbound supply | Supplier → Planning |
| #1248 Item Workspace | Cost/supplier info enriches item evidence | Supplier → Workspace |
| #1249 Exception Queue | Reorder rules feed exception evaluation | Supplier → Exceptions |
| #1251 Control Tower | Supplier/cost context in operator view | Supplier → UI |

### Non-Goals (Phase One)

Per the epic's established constraints, the following are explicitly out of scope:

- Forecasting and demand prediction
- Safety-stock optimization algorithms
- Automated replenishment without human approval
- Multi-echelon allocation
- Scenario planning / what-if analysis
- EDI/carrier integrations (beyond Amazon Business)
- Supplier performance scoring
- Contract management
- RFQ/bidding workflows

---

## 5. Glossary

| Term | Definition |
|------|------------|
| **ASIN** | Amazon Standard Identification Number — unique product identifier in Amazon's catalog |
| **Catalog Item** | A normalized representation of a purchasable product from any supplier |
| **Channel Adapter** | A pluggable module that handles communication with a specific supplier platform |
| **COGS** | Cost of Goods Sold — the direct cost of inventory items sold to customers |
| **Guided Buying** | Policies that steer purchasers toward preferred suppliers or items |
| **Lead Time** | Days between placing an order and receiving goods |
| **MOQ** | Minimum Order Quantity — the smallest amount a supplier will sell |
| **Punchout** | A protocol (cXML/OCI) for browsing a supplier's catalog from within a procurement system |
| **Reorder Point** | The inventory level at which a new purchase order should be triggered |
| **Three-Way Match** | Reconciliation of purchase order, goods receipt, and supplier invoice |
| **SP-API** | Amazon Selling Partner API — Amazon's API platform for catalog and commerce operations |
| **PA-API** | Product Advertising API — Amazon's API for product search and pricing data |

---

## 6. Decision Log

| Decision | Rationale | Date |
|----------|-----------|------|
| Amazon Business as primary channel | Largest catalog, business-tier pricing, API access, tax exemption support | 2026-08-25 |
| Price as time-series, not mutable field | Prices fluctuate; historical cost data needed for COGS, analytics, and trend detection | 2026-08-25 |
| Channel adapter pattern | Allows adding suppliers without modifying core procurement logic | 2026-08-25 |
| Extend existing PO model (#1247) | Avoids parallel purchase tracking; leverages existing commitment/inbound/receipt flow | 2026-08-25 |
| Declarative reorder rules | Deterministic, auditable, testable; avoids opaque automation | 2026-08-25 |
| Phase approach (manual → semi-auto → full) | Reduces risk; validates assumptions before investing in full automation | 2026-08-25 |
