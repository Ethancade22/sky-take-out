# Sky Take-Out Agent Guide

> This document is the single source of truth for any AI agent working with this project.
> It provides: project overview, structural map, code-reading strategy, and a pedagogical framework for teaching.

---

## 1. What This Project Is

A **food-delivery ordering system** (clone of Meituan/Waimai) built as a Spring Boot 2.7 monolith with two frontends:

| Dimension | Detail |
|-----------|--------|
| Backend | Spring Boot 2.7.3 + MyBatis + MySQL + Redis + WebSocket |
| Admin frontend | Vue 3 + TypeScript + Element UI (PC web) |
| User frontend | WeChat Mini Program / UniApp |
| Purpose | 12-day course taking a learner from zero to a complete production-style app |

The project is structured as courseware -- each `dayXX` folder under `Source/` contains incremental materials (code, docs, installers) for that day's lesson. The completed reference implementation lives at `Source/day12/complete-project-code/sky-take-out/`.

### Key Paths (all paths relative to project root)

| Resource | Path |
|----------|------|
| Complete code | `Source/day12/complete-project-code/sky-take-out/` |
| Initial scaffold | `Source/day01/backend-initial-project/sky-take-out/` |
| Admin frontend | `front-end-course/code/day03/` |
| Frontend source | `front-end-source/sky-take-out-admin/` |
| WeChat mini-program | `wechat-mini-program/` |
| Lecture notes | `lecture-notes/dayXX/` |
| Day N materials | `Source/dayXX/` |
| Videos | `video/dayXX/` |

---

## 2. Project Architecture at a Glance

```
                    ┌──────────────────────────────────────────┐
                    │           sky-take-out (Maven parent)     │
                    └──────────┬───────────┬────────────────────┘
                               │           │
              ┌────────────────┘           └────────────────┐
              ▼                                             ▼
      sky-common                                     sky-pojo
   (utils, constants,        sky-server              (Entity, DTO, VO)
    exceptions, configs)   (controllers, services,
                            mappers, etc.)
```

### Three Maven modules

1. **sky-common** -- foundational utilities: `JwtUtil`, `AliOssUtil`, `HttpClientUtil`, `WeChatPayUtil`, custom exceptions (12 classes), `Result`/`PageResult` response wrappers, `BaseContext` (ThreadLocal user ID), config property classes.
2. **sky-pojo** -- all data objects: 11 `entity` classes (one per DB table), `dto` package (request params), `vo` package (response data). No logic, pure data.
3. **sky-server** -- the actual Spring Boot application. Contains all controllers (split into `admin/` and `user/` packages), services, mappers, interceptors, config, AOP, tasks, websocket.

### Dependency chain
```
sky-server  ──depends-on──>  sky-pojo  ──depends-on──>  sky-common
sky-server  ──also-depends-on──>  sky-common (directly)
```

### Layered architecture

Every feature follows the same 4-layer pattern:

```
HTTP request
  → JWT interceptor (parses token, stores userId in ThreadLocal)
  → Controller (receives DTO, calls Service, returns Result<VO>)
  → Service interface + impl (business logic, @Transactional)
  → Mapper interface + XML (MyBatis SQL, @AutoFill for common fields)
  → MySQL
```

### Dual-tenant URL design

Both admin and user frontends hit the same backend, distinguished by URL prefix:

| Tenant | Prefix | JWT key | JWT header | Interceptor |
|--------|--------|---------|------------|-------------|
| Admin | `/admin/**` | `itcast` | `token` | `JwtTokenAdminInterceptor` |
| User | `/user/**` | `itheima` | `authentication` | `JwtTokenUserInterceptor` |

They share the same Service and Mapper layers -- only the controllers and interceptors differ.

---

## 3. Database Schema (11 tables)

### ER relationships
```
employee ────────────────────────────────────────────────
     │ (create_user/update_user -- audit fields)
     ▼
category ──1:N──> dish ──1:N──> dish_flavor
     │                │
     │                └──N:M──> setmeal_dish <──N:1── setmeal
     │                                               │
     └──────────────1:N──────────────────────────────┘

user ──1:N──> address_book
  │
  ├──1:N──> shopping_cart
  │
  └──1:N──> orders ──1:N──> order_detail
```

### Order status state machine
```
1 PendingPayment → 2 PendingAccept → 3 Accepted → 4 Delivering → 5 Completed
      ↓                   ↓
      6 Cancelled         6 Cancelled
                          ↓
                          7 Refund
```

---

## 4. Core Technical Mechanisms

These are the mechanisms that recur throughout the codebase. An agent should understand each one before answering detailed code questions.

### 4.1 JWT Authentication
- **Login**: Admin verifies password (MD5 hash) against `employee` table. User calls WeChat API for `openid`, auto-registers if new.
- **Token generation**: `JwtUtil.createJWT(secretKey, ttl, claims)` -- HS256, 2-hour TTL.
- **Every request**: Interceptor extracts token from header, parses it, stores `userId` in `BaseContext` (ThreadLocal).
- **Key files**: `JwtUtil`, `JwtProperties`, `JwtTokenAdminInterceptor`, `JwtTokenUserInterceptor`, `WebMvcConfiguration` (registers interceptors).

### 4.2 AutoFill (AOP + custom annotation)
- **Problem**: 4 audit fields (`create_time`, `update_time`, `create_user`, `update_user`) appear in most tables.
- **Solution**: `@AutoFill(OperationType.INSERT)` or `@AutoFill(OperationType.UPDATE)` on Mapper methods. An aspect (`AutoFillAspect`) intercepts these, uses reflection to call setters.
- **Key files**: `@AutoFill` annotation, `AutoFillAspect`, `AutoFillConstant`.

### 4.3 Global Exception Handling
- `GlobalExceptionHandler` with `@RestControllerAdvice` catches `BaseException` subtypes and SQL constraint violations, returning user-friendly error messages.
- Duplicate-entry errors are parsed to extract the conflicting value.

### 4.4 Redis Caching (3 strategies)
1. **Shop status**: Simple key-value (`SHOP_STATUS` = `1`/`0`), managed via `StringRedisTemplate`.
2. **Dish cache**: Manual cache with pattern-based cleanup (`dish_*` keys, cleared on admin dish changes).
3. **Setmeal cache**: Spring Cache annotations (`@Cacheable`, `@CacheEvict`) with cache name `setmealCache`.

### 4.5 WebSocket (real-time push)
- `@ServerEndpoint("/ws/{sid}")` maintains a static `sessionMap`.
- Two message types: new order notification (type=1, after payment), rush order reminder (type=2, user-initiated).
- `sendToAllClient()` broadcasts to all connected admin browsers.

### 4.6 Scheduled Tasks
- **Order timeout**: `@Scheduled(cron = "0 * * * * ?")` -- every minute, cancels orders unpaid for >15 minutes.
- **Delivery timeout**: `@Scheduled(cron = "0 0 1 * * ?")` -- daily at 1am, completes orders delivering for >60 minutes.

### 4.7 File Upload (Alibaba Cloud OSS)
- `CommonController.upload()` receives MultipartFile → `AliOssUtil.upload()` → returns public URL.
- URL stored in `dish.image` or `setmeal.image`.

### 4.8 Excel Export (Apache POI)
- `ReportController.export()` fills a template (`operation-data-report-template.xlsx`) with 30-day operational data.
- Overview section + daily detail rows.

---

## 5. API Reference Summary

### Admin APIs (`/admin/**`) -- 9 controllers, ~40 endpoints
- **Employee** (7): login, logout, CRUD, status toggle
- **Category** (6): CRUD, list by type
- **Dish** (7): CRUD with flavors, status toggle, list by category
- **Setmeal** (6): CRUD with dish associations, status toggle
- **Order** (8): search, statistics, confirm/reject/cancel/delivery/complete
- **Report** (5): turnover/user/order/top10 statistics + Excel export
- **Shop** (2): set/get status (Redis)
- **Workspace** (4): business data overview
- **Common** (1): file upload

### User APIs (`/user/**`) -- 7 controllers, ~20 endpoints
- **User** (1): WeChat login
- **Shop** (1): get status
- **AddressBook** (7): CRUD, set/get default
- **Category** (1): list by type
- **Dish** (1): list by category (cached)
- **Setmeal** (2): list by category (cached), dish details
- **ShoppingCart** (4): add/list/clean/subtract
- **Order** (7): submit/payment/history/detail/cancel/reorder/reminder

### Payment callback: `ANY /notify/paySuccess`

---

## 6. Source Code Reading Guide (for teaching learners)

This section tells an agent **how to teach a human to read and understand this codebase**. The methods below are drawn from CS education research (SIGCSE, Felienne Hermans, practitioner consensus) and adapted specifically for this Spring Boot project.

### 6.1 The Core Principle: Structured Tracing, Not Passive Browsing

Research shows that simply "reading code" does not work for learners. The most effective approach is **structured code tracing**: explicitly teach a step-by-step strategy, then have learners apply it repeatedly. A 5-minute strategy lesson improved tracing performance by 15% with 46% less variance (Xie, SIGCSE 2018).

**The strategy to teach:**
1. Understand the question (what are you trying to find out?)
2. Find where execution begins
3. Trace line-by-line, step-by-step
4. Use a "memory table" to track variable/object state changes

### 6.2 Diagnose Confusion Type Before Helping

When a learner is stuck, they are experiencing one of three distinct cognitive barriers (Hermans, *The Programmer's Brain*):

| Barrier | Symptom | Remedy |
|---------|---------|--------|
| **Lack of knowledge** | "I don't know what this annotation/keyword does" | Teach the construct directly. Point to docs. |
| **Lack of information** | "I can't find where this is defined" | Help them navigate. Show Ctrl+Click, search tools. |
| **Lack of processing power** | "This is too much, I'm lost" | Break into smaller chunks. Use external representations (diagrams, tables). |

Always diagnose first, then apply the correct remedy.

### 6.3 Four-Level Reading Framework

Structure learning through progressively deeper reading levels:

**Level 1 -- Elementary (Day 01)**
- Can you parse the Java syntax?
- Do you understand annotations like `@RestController`, `@Autowired`, `@RequestMapping`?
- Action: Read `SkyApplication.java`, `application.yml`. Understand what `@SpringBootApplication` does.

**Level 2 -- Inspectional (Day 01-02)**
- Can you skim a class and identify its role?
- Do you see the package structure pattern (`controller`/`service`/`mapper`)?
- Action: List all classes in `sky-server`, categorize them by layer. Draw the package tree.

**Level 3 -- Analytical (Day 02-09)**
- Can you trace a single feature end-to-end?
- Do you understand how the layers connect?
- Action: Pick one endpoint (e.g., `GET /admin/employee/page`). Trace from URL → Controller → Service → Mapper → SQL → response. Draw a numbered sequence diagram.

**Level 4 -- Comparative (Day 10-12)**
- Can you compare this project's approach to alternatives?
- Do you understand *why* the authors made certain design choices?
- Action: Compare manual Redis caching (dish) vs. Spring Cache (setmeal). Discuss trade-offs. Compare this project's auth with Spring Security.

### 6.4 The Recommended Reading Order for This Project

Follow this specific sequence, designed for the Sky Take-Out codebase:

#### Phase 1: Orient (before opening any Java file)
1. Read `sky-take-out/pom.xml` -- understand the three modules and all dependencies.
2. Read `application.yml` + `application-dev.yml` -- understand configuration structure, datasource, Redis, JWT settings.
3. Look at the database: run `sky.sql`, examine all 11 tables. Draw the ER diagram on paper.
4. Start the application, open Swagger at `http://localhost:8080/doc.html`. Try a few endpoints. See the full picture.

#### Phase 2: Trace the simplest happy path
5. Read `EmployeeController.login()` (the very first endpoint a user hits).
6. Trace: `Controller.login()` → `EmployeeService.login()` → `EmployeeMapper.getByUsername()` → `EmployeeMapper.xml` SQL.
7. Understand every class touched: `EmployeeLoginDTO`, `Employee`, `EmployeeLoginVO`, `Result`, `JwtUtil`, `JwtProperties`, `BaseContext`.

#### Phase 3: Understand the infrastructure layer
8. Read `WebMvcConfiguration.java` -- understand how JWT interceptors are registered.
9. Read `JwtTokenAdminInterceptor.java` -- understand request interception, token parsing, ThreadLocal storage.
10. Read `GlobalExceptionHandler.java` -- understand unified error handling.
11. Read `AutoFillAspect.java` + `@AutoFill` -- understand AOP-based field filling.

#### Phase 4: Read one CRUD module deeply (Employee)
12. Read all Employee endpoints: page query, add, update, status toggle, get by ID.
13. For each: trace Controller → Service → Mapper → XML.
14. Pay attention to: `PageHelper.startPage()`, `BeanUtils.copyProperties()`, DTO vs Entity vs VO conversion.

#### Phase 5: Read progressively more complex modules
15. **Category** (Day 02): simple CRUD with type filtering. Notice reusability patterns.
16. **Dish** (Day 03): CRUD + sub-entity (dish_flavor). Notice how one-to-many is handled in Service. Notice OSS upload.
17. **Setmeal** (Day 04): many-to-many via `setmeal_dish`. Notice `@Transactional` usage. Notice cascade status logic (dish stop → setmeal stop).
18. **Shop** (Day 05): Redis intro. Simple key-value read/write. First encounter with `StringRedisTemplate`.
19. **User login** (Day 06): `HttpClientUtil` calling WeChat API. Notice openid flow, auto-registration.
20. **Dish cache** (Day 07): manual Redis caching with `cleanCache("dish_*")`. Compare with previous direct DB queries.
21. **Shopping cart** (Day 07): user-scoped queries (`BaseContext.getCurrentId()`). Add/subtract logic.
22. **Order submit** (Day 08): the most complex transaction. Multiple inserts, cart clearing, address validation.
23. **WebSocket** (Day 10): event-driven push after payment. Read `WebSocketServer` + `WebSocketTask`.
24. **Statistics** (Day 11-12): aggregation SQL in Mapper XML. Apache POI template filling.

### 6.5 Teaching Techniques (for agent-human interaction)

When an agent is helping a human learn this codebase, use these techniques:

#### Technique 1: Think Aloud Modeling
When showing code, narrate your reasoning process explicitly:
```
"I see @AutoFill(OperationType.INSERT) on this mapper method. That tells me the
AutoFillAspect will intercept this call. Let me check what fields get filled for
INSERT operations... looking at AutoFillAspect, it calls entity.setCreateTime() and
entity.setCreateUser(). So the developer doesn't need to set these manually -- the
AOP handles it."
```

#### Technique 2: Question-Driven Reading ("Detective Method")
Before diving into code, ask the learner to formulate specific questions:
- "What happens when a dish is marked as stopped selling?"
- "How does the system know which user is making this request?"
- "Where is the cache invalidated when an admin updates a dish?"

Have them read specifically to answer those questions. This creates purpose-driven learning.

#### Technique 3: Memory Tables
For complex methods, have the learner track variable state:

| Line | Variable | Value | Notes |
|------|----------|-------|-------|
| 45 | `shoppingCartList` | [item1, item2] | from DB by userId |
| 48 | `orderNumber` | "2024010112345678" | generated unique ID |
| 52 | `orders` | Orders{status: 1, ...} | being constructed |
| 58 | `orderDetailList` | [detail1, detail2] | built from cart items |

This prevents the "I got lost in the middle" problem.

#### Technique 4: Draw Maps While Reading
Require the learner to maintain a growing diagram as they read. Each session adds something:
- After Phase 1: package structure diagram
- After Phase 2: sequence diagram for login
- After Phase 3: interceptor flow diagram
- After each new module: add to the growing architecture map

#### Technique 5: Main Line First, Branches Later
When tracing a complex flow (like order submission), first trace only the happy path:
```
submitOrder → validate address → validate cart → insert order → insert details → clear cart → return
```
Skip error handling, edge cases, and helper methods on the first pass. Mark them as TODO for a second pass.

#### Technique 6: Build, Break, Modify
After reading a module, give hands-on challenges:
- "Change the JWT token TTL from 2 hours to 30 minutes. What file do you change?"
- "Add a log statement in `EmployeeServiceImpl.login()` that prints the employee name after successful login."
- "What happens if you comment out `@AutoFill` on `EmployeeMapper.insert()`? Try it."
- "Add a new field `nickname` to the `employee` table and make it visible in the admin panel."

#### Technique 7: Write to Teach
After completing a module, ask the learner to produce output:
- Write a blog-post-quality explanation with diagrams
- Give a 5-minute presentation explaining a module
- Create an annotated sequence diagram for a specific flow
- Write 3 test cases that demonstrate they understand the behavior

### 6.6 Day-by-Day Reading Assignments

For each day, here is what the learner should read, trace, and understand:

#### Day 01 -- Foundation
- **Read**: `pom.xml` (all three), `application.yml`, `application-dev.yml`, `SkyApplication.java`
- **Trace**: Boot process -- how Spring scans packages, loads config, registers beans
- **Understand**: Maven multi-module structure, Spring Boot starter dependencies, YAML configuration with property references
- **Exercise**: Start the app, hit Swagger, call `POST /admin/employee/login` with `admin/123456`, observe the JWT token in the response

#### Day 02 -- Employee & Category CRUD
- **Read**: `EmployeeController`, `EmployeeService`, `EmployeeServiceImpl`, `EmployeeMapper`, `EmployeeMapper.xml`
- **Trace**: Full CRUD cycle: login → page query → add → update → status toggle
- **New concepts**: `PageHelper.startPage()`, `@AutoFill`, `AutoFillAspect`, `GlobalExceptionHandler`, `BeanUtils.copyProperties()`, `BaseContext` (ThreadLocal)
- **Exercise**: Trace `addEmployee()` end-to-end. Draw a sequence diagram. Explain how `createUser`/`updateUser` gets set without the controller explicitly setting it.

#### Day 03 -- Dish Management
- **Read**: `DishController`, `DishService`, `DishServiceImpl`, `DishMapper`, `DishMapper.xml`, `DishFlavorMapper`
- **Trace**: `saveWithFlavor()` -- how a dish and its flavors are saved together
- **New concepts**: One-to-many insert, DTO/VO layered design, `DishDTO` with flavor list, `DishVO` with flavor list
- **Exercise**: Compare `DishDTO` vs `Dish` vs `DishVO`. Which fields does each have and why? Trace `getByIdWithFlavor()` and notice the two-step query (dish + flavors).

#### Day 04 -- Setmeal (Package) Management
- **Read**: `SetmealController`, `SetmealService`, `SetmealServiceImpl`
- **Trace**: `saveWithDish()` -- setmeal + associated dishes. `startOrStop()` -- cascade logic.
- **New concepts**: `@Transactional`, many-to-many via `setmeal_dish`, cascade status changes
- **Exercise**: Trace what happens when a dish is stopped (`DishServiceImpl.startOrStop()`). It should stop all setmeals containing that dish. Draw this cascade flow.

#### Day 05 -- Redis & Shop Status
- **Read**: `ShopController` (admin + user), `ShopServiceImpl`
- **Trace**: `setStatus()` writes to Redis, `getStatus()` reads from Redis
- **New concepts**: `StringRedisTemplate`, `redisTemplate.opsForValue()`, key design
- **Exercise**: Start Redis, use `redis-cli` to manually set `SHOP_STATUS` to `1`, then call the user endpoint to verify. Then change it via the admin API.

#### Day 06 -- WeChat Login & User Browsing
- **Read**: `UserController` (user), `UserServiceImpl`, `HttpClientUtil`
- **Trace**: `login()` -- receive code → call WeChat API → get openid → query/create user → return JWT
- **New concepts**: `HttpClientUtil.doGet()`, WeChat `jscode2session` API, auto-registration pattern
- **Exercise**: Read `WeChatProperties` to see how the WeChat appid/secret are configured. Trace what would happen if a user logs in for the first time (the INSERT path).

#### Day 07 -- Caching & Shopping Cart
- **Read**: `DishServiceImpl` (user-side, cached version), `SetmealServiceImpl` (user-side, Spring Cache version), `ShoppingCartController`, `ShoppingCartServiceImpl`
- **Trace**: User `listDish()` -- first call hits DB and caches; second call hits Redis. Compare with `listSetmeal()` which uses `@Cacheable`.
- **New concepts**: Manual Redis cache vs. Spring Cache, cache invalidation patterns, `cleanCache("dish_*")`, `@CacheEvict`
- **Exercise**: Add a dish, verify the cache key pattern. Update the dish, verify the cache is cleared.

#### Day 08 -- Order & Payment
- **Read**: `OrderController` (user), `OrderServiceImpl`, `UserAddressController`
- **Trace**: `submitOrder()` -- the most complex transaction in the project
- **New concepts**: Multi-table transaction, `@Transactional` on complex operations, `OrdersSubmitDTO`, `OrderSubmitVO`
- **Exercise**: Trace every database insert in `submitOrder()`. Count how many tables are touched. What would happen if the `order_detail` insert failed halfway?

#### Day 09 -- Order Management (both sides)
- **Read**: `OrderController` (admin), `OrderServiceImpl` (confirm/reject/cancel/delivery/complete methods)
- **Trace**: `confirm()` → `rejection()` → what happens to payment refund. `cancel()` from admin side vs user side.
- **Exercise**: Draw the complete order state machine. For each transition, note: which endpoint triggers it, what validations apply, whether refund logic runs.

#### Day 10 -- Scheduled Tasks & WebSocket
- **Read**: `OrderTask` (scheduled), `WebSocketServer`, `WebSocketConfiguration`
- **Trace**: `processTimeoutOrder()` -- find expired orders, cancel them. `WebSocketServer.sendToAllClient()` -- how messages reach all admin browsers.
- **New concepts**: `@Scheduled`, `@EnableScheduling`, `@ServerEndpoint`, `@OnOpen`/`@OnClose`/`@OnMessage`, static `ConcurrentHashMap` for sessions
- **Exercise**: Read the payment callback (`paySuccess`). Trace: payment confirmed → update order status → create WebSocket message → push to admin. Draw this async flow.

#### Day 11 -- Statistics (Charts)
- **Read**: `ReportController`, `ReportService`, `ReportServiceImpl`, `OrderMapper` (statistics SQL)
- **Trace**: `turnoverStatistics()` -- query aggregated data by date range, return as `TurnoverReportVO` with date list + turnover list
- **New concepts**: SQL aggregation (`SUM`, `COUNT`, `GROUP BY DATE`), building list-format response data for ECharts
- **Exercise**: Read the Mapper XML for turnover statistics. Rewrite the SQL to get weekly aggregation instead of daily. What would change in the VO?

#### Day 12 -- Excel Export
- **Read**: `ReportController.export()`, `ReportServiceImpl.getBusinessData()`, `WorkSpaceController`
- **Trace**: `export()` -- query data → load template → fill overview section → fill daily detail rows → write to response stream
- **New concepts**: Apache POI `XSSFWorkbook`, template-based Excel generation, streaming response
- **Exercise**: Trace how the template file is loaded and which cells get filled. Add a new summary metric (e.g., average order amount) to the export.

---

## 7. Agent Behavior Guidelines

When an agent works with a learner on this project, follow these rules:

### 7.1 Before answering code questions
- **Always locate the actual file first.** Do not answer from memory of the guide alone. Read the source code before explaining it.
- **Reference specific file paths.** e.g., "In `sky-server/src/main/java/com/sky/service/impl/EmployeeServiceImpl.java:45`..."

### 7.2 When explaining code
- **Trace the request flow, not just the method.** Never explain a Service method in isolation. Show: Controller → Service → Mapper → SQL.
- **Connect to the architecture.** When explaining a specific feature, explicitly name the pattern it uses (e.g., "This is the DTO pattern -- the controller receives an `EmployeeDTO` to avoid exposing the full `Employee` entity").
- **Distinguish knowledge levels.** Mark explanations as: `[Syntax]` (Java language feature), `[Framework]` (Spring/MyBatis mechanism), or `[Design]` (architectural pattern).

### 7.3 When the learner is stuck
1. Ask: "What specifically are you trying to understand?" (Define the question.)
2. Ask: "Which part is confusing -- the syntax, where to find something, or the overall flow?" (Diagnose confusion type.)
3. If syntax: explain the construct directly with a mini-example.
4. If navigation: help them locate the file, show the search path.
5. If flow overload: break it into smaller steps, use a diagram or memory table.

### 7.4 When reviewing learner code
- Start by naming something the code does well before any criticism.
- If the learner made a mistake, trace the consequence: "If this null check is missing, then when a user submits an order with an empty cart, the Service will try to iterate over `null` at line 78, causing a NullPointerException."
- Connect fixes back to the architecture: "This is why we validate in the Service layer, not just the Controller."

### 7.5 Common learner mistakes in this project
| Mistake | Explanation |
|---------|-------------|
| Forgetting `@AutoFill` on new Mapper methods | The audit fields won't be populated, causing NULL in DB |
| Confusing DTO vs Entity vs VO | Each has a specific role -- DTO receives input, Entity maps to DB, VO shapes output |
| Not calling `PageHelper.startPage()` before the query | Pagination won't work, returns all rows |
| Forgetting `@Transactional` on multi-table operations | Partial failures can leave data inconsistent |
| Using wrong JWT interceptor for the endpoint type | Admin token won't work on `/user/**` endpoints and vice versa |
| Not clearing cache after admin data changes | Users see stale data until cache expires |
| Missing `BaseContext.getCurrentId()` for user-scoped queries | Returns data for all users instead of the current user |

---

## 8. Quick Reference: File-to-Concept Map

When a learner asks about a concept, point them to these files:

| Concept | Primary files |
|---------|--------------|
| Maven multi-module | `pom.xml` (parent), `sky-common/pom.xml`, `sky-pojo/pom.xml`, `sky-server/pom.xml` |
| Spring Boot config | `application.yml`, `application-dev.yml` |
| JWT auth | `JwtUtil`, `JwtProperties`, `JwtTokenAdminInterceptor`, `JwtTokenUserInterceptor` |
| ThreadLocal user context | `BaseContext` |
| AOP auto-fill | `@AutoFill`, `AutoFillAspect`, `AutoFillConstant` |
| Global exception handling | `GlobalExceptionHandler`, `BaseException` and subclasses |
| MyBatis CRUD | Any `*Mapper.java` + corresponding `*Mapper.xml` |
| Pagination | `PageHelper.startPage()` in Service impls |
| DTO/VO/Entity pattern | `sky-pojo` module: `entity/`, `dto/`, `vo/` packages |
| Redis caching | `ShopServiceImpl`, user-side `DishServiceImpl`, user-side `SetmealServiceImpl` |
| Spring Cache | `@Cacheable`/`@CacheEvict` on `SetmealServiceImpl` |
| File upload | `CommonController`, `AliOssUtil`, `AliOssProperties` |
| WeChat login | `UserController` (user), `UserServiceImpl`, `HttpClientUtil` |
| Shopping cart | `ShoppingCartController`, `ShoppingCartServiceImpl` |
| Order submission | `OrderController.submit()`, `OrderServiceImpl.submitOrder()` |
| WebSocket | `WebSocketServer`, `WebSocketConfiguration` |
| Scheduled tasks | `OrderTask`, `@EnableScheduling` in `SkyApplication` |
| Statistics SQL | `ReportController`, `ReportServiceImpl`, `OrderMapper.xml` (custom SQL) |
| Excel export | `ReportController.export()`, Apache POI template at `Source/day12/operation-data-report-template.xlsx` |
