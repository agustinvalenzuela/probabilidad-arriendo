-- ============================================================================
-- query_analisis.sql
-- Tabla base UNICA para el analisis exploratorio de velocidad de arriendo.
-- Una sola sentencia. Reemplaza query.sql, query2.sql, query3.sql, query4.sql
-- y query_demanda.sql.
-- ----------------------------------------------------------------------------
-- GRANO: una fila por property_id. Sin DISTINCT, sin duplicados por join.
--
-- EL FILTRO QUE HACE POSIBLE TODO ESTO
--   p.created >= '2025-07-01'
-- property_publication_metrics arranca el 2025-07-23. Con el universo anterior
-- (created >= 2025-01-01) habia cohortes enteras cuyas visitas eran cero por
-- ausencia de tabla, no por ausencia de demanda. Alineando el universo con la
-- cobertura de la fuente, un cero en visitas vuelve a significar lo que dice.
--
-- Y de paso resuelve el rendimiento: como toda ventana empieza despues del
-- 2025-07-01, las tres tablas de eventos se pueden podar por fecha ANTES de
-- cualquier join. Eso importa sobre todo en bi_DimLeadAttemps, que tiene
-- 1.224.012 filas y cuyo unico indice es idx_created_at: el join por
-- property_id no tiene por donde entrar, pero el filtro por fecha si.
--
-- ----------------------------------------------------------------------------
-- LAS TRES REGLAS QUE MANTIENEN ESTA QUERY RAPIDA
--
-- REGLA 1 · bi_DimProperties se toca UNA vez.
--   103.844 filas en 171 MB, y el optimizador descarta idx_property_id porque el
--   filtro por unit_type / mf / pais_id pasa el 0,03%: es un scan completo.
--   `prop` se referencia solo desde `uni`. Una version anterior de este archivo
--   "optimizo" podando lpa, ctr y ml contra prop: subio las referencias de 1 a 4
--   y la query paso de minutos a mas de veinte. MySQL no garantiza materializar
--   un CTE una sola vez, asi que cada referencia puede repetir toda la cadena.
--
-- REGLA 2 · Lo que se referencia varias veces tiene que ser barato.
--   `lpa` se referencia seis veces (uni, chk, ctr, res y las agregaciones de
--   visitas y leads) y `mov` dos, pero property_state_movements se lee UNA sola
--   vez: el plan entra por idx_property_state_movements_estado_vacios y se queda
--   en ~67.000 filas por estado, no en las 871.530 de la tabla.
--
-- REGLA 3 · Precio por subconsultas correlacionadas, demanda por joins agrupados.
--   historical_pricing TIENE el indice compuesto (property_id, created_at): cada
--   subconsulta es un lookup de ~15 filas, y query4 ya lo hacia asi a 2-3 minutos.
--   Las tablas de demanda NO tienen indice por property_id, asi que ahi una
--   correlacion por fila seria un scan completo por unidad; van con GROUP BY de
--   una sola pasada.
--
-- ----------------------------------------------------------------------------
-- VENTANA DE DEMANDA: FIJA A 90 DIAS, sin recorte por el evento.
--   Antes era [fecha_LPA, LEAST(event_date, +90d)). Cortar en el evento obliga a
--   que las tres agregaciones dependan de la cadena cara (contratos +
--   fecha_desactivacion), que es justamente de donde venia el problema. Con
--   ventana fija dependen solo de `lpa`.
--   Ademas es mejor analisis: con ventana variable, la unidad que se arrendo el
--   dia 5 tiene 5 dias de exposicion y la que churneo el dia 80 tiene 80, asi que
--   comparar sus conteos es comparar el reloj, no la demanda.
--   El supuesto es que una unidad arrendada sale de publicacion y deja de generar
--   filas. Es VERIFICABLE con columnas que ya salen de aca: si
--   no_modelo_last_visit_obs > no_modelo_event_date es raro, el supuesto se
--   sostiene. El notebook lo comprueba en el paso 2 (check 4, mas abajo).
--
-- ----------------------------------------------------------------------------
-- CONVENCION DE NOMBRES
--   sin prefijo    -> conocido en fecha_LPA. Usable como feature ex-ante.
--   no_modelo_     -> mira despues de fecha_LPA. Solo descriptivo / target.
--   d0_7_          -> ventana landmark dias 0 a 7. Usable ex-ante para predecir
--                     el desenlace de los dias 8 en adelante, CONDICIONADO a
--                     sobrevivir al dia 7 (ver sobrevive_d7).
--   flag_ / motivo_-> diagnostico de calidad de dato.
--
-- MEDIDAS DE VELOCIDAD
--   no_modelo_days_to_event    dias de LPA al CIERRE. Para una unidad arrendada
--                              el cierre es la primera RESERVA, no el contrato:
--                              ahi es cuando deja el mercado. Si no hay reserva
--                              registrada cae al contrato, y para el churn es la
--                              baja. NULL si sigue en mercado.
--                              Ver no_modelo_origen_event_date para la mezcla.
--   no_modelo_days_to_contrato dias de LPA a la creacion del contrato. Es la
--                              medida anterior; queda para cuantificar el cambio.
--   no_modelo_days_to_reserva  dias de LPA a la primera reserva, sin fallback.
--   no_modelo_days_to_check_in dias de LPA a "Esperando Check-In". OJO: este
--                              estado es POSTERIOR al contrato en el 95% de los
--                              casos medidos, no anterior. Es la espera del
--                              check-in fisico del arrendatario, no el cierre.
--   no_modelo_dias_contrato_a_check_in  coordinacion de la entrega.
--   no_modelo_dias_reserva_a_contrato   tramitacion del contrato.
--   no_modelo_dias_observados  dias de LPA al evento, o a HOY. Nunca NULL.
--   no_modelo_censurada        1 = sigue buscando, la duracion real es MAYOR.
--   El par (dias_observados, censurada) es lo que consume un Kaplan-Meier o un
--   Cox. Usar solo days_to_event y descartar los NULL reintroduce el sesgo de
--   seleccion: las unidades mas lentas son las que aun no tienen evento. Los
--   targets binarios (<= 15 / 20 / 30 dias) se derivan en el notebook, para no
--   fijar el horizonte en SQL.
--
-- ----------------------------------------------------------------------------
-- POR QUE EL CIERRE ES LA RESERVA. Medido contra la base el 2026-08-28 sobre
-- las 2.547 unidades del universo con contrato posterior al LPA:
--
--   orden de los hitos    reserva ANTES del contrato     74,1%
--                         check-in DESPUES del contrato  94,7%
--                         "Arrendado" antes del contrato  0,8%  (19 de 2.427)
--
--   dias LPA -> contrato  media 44,4
--   dias LPA -> cierre    media 39,7     tramitacion media: 4,7 dias
--
--   tasa de colocacion    <=15d  25,9% -> 32,2%
--   (contrato -> cierre)  <=20d  33,1% -> 40,0%
--                         <=30d  47,0% -> 52,9%
--
-- Casi siete puntos en el horizonte de 20 dias que antes se contaban como
-- lentitud de mercado y eran tramitacion. El 9,6% tiene mas de una reserva: en
-- esas la primera no es el cierre (ver no_modelo_n_reservas_pre_contrato).
-- ----------------------------------------------------------------------------
--
-- TAMANO MEDIDO del universo el 2026-08-28: 7.683 properties, 4.224 con LPA,
-- 3.862 analizables, 2.547 arrendadas, 44,4% censuradas. La query completa
-- corrio en 16 segundos.
--
-- ESTA QUERY NO FILTRA EN SILENCIO. Las unidades sin LPA, sin precio o con
-- ventana invalida salen igual, marcadas en motivo_exclusion. El descarte se
-- hace en pandas, donde queda contado. En el diagnostico previo esto no era
-- teorico: las unidades sin fecha LPA eran ~20% de la muestra y tenian 96% de
-- churn; un INNER JOIN las borraba junto con el hallazgo.
-- ============================================================================

WITH
-- ---------------------------------------------------------------------------
-- mov · Una sola lectura de property_state_movements para los DOS estados que
-- importan. El plan entra por idx_property_state_movements_estado_vacios, asi
-- que se queda en ~67.000 filas por estado y no en las 871.530 de la tabla.
--
-- Se filtra por ID y no por nombre. Los 13 estados fueron consultados contra la
-- base el 2026-08-28 y estos son los que importan:
--     8  Lista para arrendar   190.217 movimientos · 80.539 properties
--    13  Esperando check-in    108.004 movimientos · 63.603 properties
--     6  Arrendado             186.525 movimientos · 83.882 properties
-- Usar el id evita la union con estados_vacios y el LOWER(TRIM()) por fila, que
-- impedia cualquier uso de indice sobre el nombre.
--
-- El estado 6 "Arrendado" NO se usa, y conviene dejar escrito por que para que
-- nadie lo reintente: de 2.427 unidades arrendadas que lo tienen, solo 19 lo
-- registran ANTES del contrato. Igual que el check-in, es posterior al cierre.
-- ---------------------------------------------------------------------------
mov AS (
    SELECT
        pm.property_id,
        pm.fecha_inicio,
        pm.estado_vacios AS estado
    FROM assetplan_rentas.property_state_movements pm
    WHERE pm.estado_vacios IN (8, 13)
),
-- ---------------------------------------------------------------------------
-- lpa · Primer periodo "Lista para arrendar". MIN en vez de ROW_NUMBER: hace
-- exactamente lo mismo y se lee mejor.
-- ---------------------------------------------------------------------------
lpa AS (
    SELECT property_id, MIN(fecha_inicio) AS fecha_LPA
    FROM mov
    WHERE estado = 8
      -- Ninguna unidad del universo pudo estar lista antes de existir, y el
      -- universo empieza el 2025-07-01. Poda sin perdida.
      AND fecha_inicio >= '2025-07-01'
    GROUP BY property_id
),
-- ---------------------------------------------------------------------------
-- chk · Primera entrada a "Esperando Check-In" posterior al LPA.
--
-- MEDIDO, no supuesto. La hipotesis inicial era que este estado precedia al
-- contrato y que por lo tanto days_to_event venia inflado por el papeleo. Los
-- datos dicen lo contrario: sobre 2.235 unidades arrendadas y analizables, el
-- 100% tiene el movimiento y en el 95% ocurre DESPUES de created_at del
-- contrato. Es la espera del check-in fisico del arrendatario, que sucede una
-- vez firmado, no un paso comercial previo.
--
-- Se conserva igual porque mide la coordinacion de la entrega, y porque el 5%
-- restante (flag_check_in_previo_al_contrato) marca ciclos de arriendo previos
-- o desincronizacion entre el registro de estados y el de contratos.
--
-- Se toma la PRIMERA ocurrencia posterior al LPA, no la ultima: una unidad
-- puede reciclar estados si el arriendo se cae y vuelve al mercado, y esos
-- ciclos posteriores no pertenecen a esta vacancia.
-- ---------------------------------------------------------------------------
chk AS (
    SELECT m.property_id, MIN(m.fecha_inicio) AS fecha_check_in
    FROM mov m
    INNER JOIN lpa l ON l.property_id = m.property_id
    WHERE m.estado = 13
      AND m.fecha_inicio >= l.fecha_LPA
    GROUP BY m.property_id
),
-- ---------------------------------------------------------------------------
-- ctr · Primer contrato. heredado se recalcula: si la vigencia empieza antes de
-- que el contrato se cree, el arrendatario ya estaba adentro aunque diga 0.
-- ---------------------------------------------------------------------------
ctr AS (
    SELECT
        property_id, renter_id, inicio_contrato, monto_arriendo,
        CASE WHEN fecha_inicio < inicio_contrato THEN 1 ELSE heredado END AS heredado
    FROM (
        SELECT
            c.property_id, c.renter_id,
            c.created_at AS inicio_contrato,
            c.fecha_inicio, c.heredado, c.monto_arriendo,
            ROW_NUMBER() OVER (PARTITION BY c.property_id
                               ORDER BY c.created_at) AS rn
        FROM bi_assetplan.bi_DimContratos c
        -- Solo contratos POSTERIORES al LPA de esta vacancia. MEDIDO el
        -- 2026-08-28 sobre las 4.224 unidades con LPA del universo:
        --   484 (11,5%) tenian su primer contrato ANTERIOR al LPA, o sea de un
        --       ciclo de arriendo previo.
        --   295 de esas no tienen ningun contrato posterior: sin este filtro se
        --       clasificaban como "arriendo" con una fecha de evento ajena a
        --       esta vacancia. Ahora quedan como churn o censuradas, que es lo
        --       que son.
        --   Las otras 189 usaban el contrato viejo en vez del nuevo.
        -- Con event_date = LEAST(reserva, contrato), un contrato viejo arrastraba
        -- ademas la fecha de cierre hacia atras.
        INNER JOIN lpa l ON l.property_id = c.property_id
        WHERE c.created_at >= l.fecha_LPA
    ) t
    WHERE rn = 1
),
-- ---------------------------------------------------------------------------
-- prop · El universo. Deduplicado por property_id. REGLA 1: una sola referencia.
--
-- DORMITORIOS / BANOS / ESTUDIO: la fuente principal es
-- aa_pmPricingExplainabilityPredictions. Son atributos fisicos de la unidad, no
-- salidas del modelo, asi que tomarlos de un snapshot actual NO es fuga temporal:
-- un departamento no cambia de dormitorios entre su fecha_LPA y hoy. Mismo
-- argumento que ggcc.
-- Lo de abajo es el RESPALDO, parseado de nombre_tipologia, para las unidades sin
-- fila en esa tabla. Valores reales de la columna (12.309 filas):
--   1D1B 4.775 | 2D2B 2.524 | 2D1B 2.138 | 1D2B 14 -> patron NdMb, se parsea
--   3D 1.838   -> dormitorios 3, banos desconocido por esta via
--   Estudio 887-> dormitorios 0, banos 1 (supuesto de dominio, no parseo)
--   Otro 84 | (vacio) 49 -> ambos NULL
-- Cobertura del respaldo por si solo: dormitorios 98,9% | banos 84,0%.
-- ---------------------------------------------------------------------------
prop AS (
    SELECT
        property_id, unit_id, edificio, barrio, comuna, sector_provincia,
        nombre_tipologia, m2_utiles, piso, acepta_mascotas, owner_id,
        first_time_rented, ha_sido_arrendada, actual_activa,
        created, fecha_desactivacion,
        dormitorios_tip, banos_tip, tipologia_origen
    FROM (
        SELECT
            p.property_id, p.unit_id, p.edificio, p.barrio, p.comuna,
            p.sector_provincia, p.nombre_tipologia, p.m2_utiles, p.piso,
            p.acepta_mascotas, p.owner_id, p.first_time_rented,
            p.ha_sido_arrendada, p.actual_activa, p.created,
            p.fecha_desactivacion,
            CASE
                WHEN LOWER(TRIM(p.nombre_tipologia)) REGEXP 'studio|estudio|loft' THEN 0
                ELSE CAST(NULLIF(REGEXP_REPLACE(
                        REGEXP_SUBSTR(p.nombre_tipologia, '[0-9]+[[:space:]]*[Dd]'),
                        '[^0-9]', ''), '') AS UNSIGNED)
            END AS dormitorios_tip,
            CASE
                WHEN LOWER(TRIM(p.nombre_tipologia)) REGEXP 'studio|estudio|loft' THEN 1
                ELSE CAST(NULLIF(REGEXP_REPLACE(
                        REGEXP_SUBSTR(p.nombre_tipologia, '[0-9]+[[:space:]]*[Bb]'),
                        '[^0-9]', ''), '') AS UNSIGNED)
            END AS banos_tip,
            CASE
                WHEN LOWER(TRIM(p.nombre_tipologia)) REGEXP 'studio|estudio|loft'
                    THEN 'estudio'
                WHEN p.nombre_tipologia REGEXP '[0-9]+[[:space:]]*[Dd]'
                 AND p.nombre_tipologia REGEXP '[0-9]+[[:space:]]*[Bb]'
                    THEN 'D y B'
                WHEN p.nombre_tipologia REGEXP '[0-9]+[[:space:]]*[Dd]'
                    THEN 'solo D'
                ELSE 'sin info'
            END AS tipologia_origen,
            ROW_NUMBER() OVER (PARTITION BY p.property_id ORDER BY p.created) AS rn
        FROM bi_assetplan.bi_DimProperties p
        WHERE p.unit_type = 'Appartment'
          AND p.mf       = 0
          AND p.pais_id  = 1
          -- Alineado con el inicio de property_publication_metrics (2025-07-23).
          AND p.created >= '2025-07-01'
          AND p.sector_provincia IN (
                'Santiago - Centro', 'Santiago - Surponiente', 'Santiago - Nororiente',
                'Santiago - Sur', 'Santiago - Suroriente', 'Santiago - Norte',
                'Santiago - Norponiente'
              )
    ) t
    WHERE rn = 1
),
-- ---------------------------------------------------------------------------
-- vis / lds / res · Demanda. Ventana FIJA [fecha_LPA, fecha_LPA + 90 dias), con
-- bordes semi-abiertos para que un evento del dia 7 exacto no caiga en la semana
-- 1 y en la 2 a la vez. Las tres joinean contra `lpa`, que es barato, y llevan
-- un piso constante por fecha para que la tabla se pueda podar antes del join.
-- ---------------------------------------------------------------------------
vis AS (
    SELECT
        l.property_id,
        SUM(CASE WHEN m.date_from <  l.fecha_LPA + INTERVAL  7 DAY
                 THEN m.visits_amount END)                     AS visitas_sem_1,
        SUM(CASE WHEN m.date_from >= l.fecha_LPA + INTERVAL  7 DAY
                  AND m.date_from <  l.fecha_LPA + INTERVAL 14 DAY
                 THEN m.visits_amount END)                     AS visitas_sem_2,
        SUM(CASE WHEN m.date_from >= l.fecha_LPA + INTERVAL 14 DAY
                  AND m.date_from <  l.fecha_LPA + INTERVAL 21 DAY
                 THEN m.visits_amount END)                     AS visitas_sem_3,
        SUM(CASE WHEN m.date_from >= l.fecha_LPA + INTERVAL 21 DAY
                  AND m.date_from <  l.fecha_LPA + INTERVAL 28 DAY
                 THEN m.visits_amount END)                     AS visitas_sem_4,
        SUM(CASE WHEN m.date_from >= l.fecha_LPA + INTERVAL 28 DAY
                 THEN m.visits_amount END)                     AS visitas_sem5_a_90,
        SUM(m.visits_amount)                                   AS visitas_90d,
        COUNT(DISTINCT DATE(m.date_from))                      AS dias_con_observacion,
        MIN(DATE(m.date_from))                                 AS first_visit_obs,
        MAX(DATE(m.date_from))                                 AS last_visit_obs
    FROM lpa l
    INNER JOIN assetplan_rentas.property_publication_metrics m
            ON m.property_id  = l.property_id
           AND m.property_id  > 0
           AND m.date_from   >= l.fecha_LPA
           AND m.date_from   <  l.fecha_LPA + INTERVAL 90 DAY
           AND m.date_from   >= '2025-07-01'
    GROUP BY l.property_id
),
lds AS (
    SELECT
        l.property_id,
        COUNT(DISTINCT dla.lead_id)                            AS leads_90d,
        COUNT(DISTINCT CASE WHEN dla.created_at < l.fecha_LPA + INTERVAL 7 DAY
                            THEN dla.lead_id END)              AS d0_7_leads
    FROM lpa l
    INNER JOIN bi_assetplan.bi_DimLeadAttemps dla
            ON dla.property_id  = l.property_id
           AND dla.created_at  >= l.fecha_LPA
           AND dla.created_at  <  l.fecha_LPA + INTERVAL 90 DAY
           -- Este piso es el que salva la tabla: 1,2 millones de filas y su unico
           -- indice es idx_created_at, asi que es la unica via de acceso barata.
           AND dla.created_at  >= '2025-07-01'
    GROUP BY l.property_id
),
res AS (
    -- Se quita el tope de 90 dias del JOIN y se pasa a los conteos, para poder
    -- sacar tambien la fecha de la PRIMERA reserva sin recortarla. Son 86.983
    -- filas: la pasada extra no cuesta nada.
    -- La reserva es la candidata real a "cierre comercial anterior al contrato".
    -- Ver la nota sobre el orden de los estados en el encabezado.
    SELECT
        l.property_id,
        COUNT(DISTINCT CASE WHEN r.fecha < l.fecha_LPA + INTERVAL 90 DAY
                            THEN r.reserva_id END)             AS reservas_90d,
        COUNT(DISTINCT CASE WHEN r.fecha < l.fecha_LPA + INTERVAL 7 DAY
                            THEN r.reserva_id END)             AS d0_7_reservas,
        MIN(r.fecha)                                           AS fecha_primera_reserva,
        -- La ULTIMA reserva anterior al contrato es la que con mas probabilidad
        -- convirtio. Solo difiere de la primera cuando hubo reservas caidas.
        MAX(CASE WHEN c.inicio_contrato IS NULL OR r.fecha < c.inicio_contrato
                 THEN r.fecha END)                             AS fecha_ultima_reserva_pre_contrato,
        -- El contador que delata las reservas caidas: si es > 1, la primera
        -- reserva NO es el cierre y hay que usar la ultima.
        COUNT(DISTINCT CASE WHEN c.inicio_contrato IS NULL OR r.fecha < c.inicio_contrato
                            THEN r.reserva_id END)             AS n_reservas_pre_contrato
    FROM lpa l
    INNER JOIN bi_assetplan.bi_DimReservas r
            ON r.property_id = l.property_id
           AND r.fecha      >= l.fecha_LPA
           AND r.fecha      >= '2025-07-01'
    LEFT JOIN ctr c ON c.property_id = l.property_id
    GROUP BY l.property_id
),
-- ---------------------------------------------------------------------------
-- ml · Ultima prediccion disponible. Es EX-POST: el check de cobertura ex-ante
-- (pricing_date <= fecha_LPA) dio ~0%, o sea que la tabla es un snapshot que se
-- sobreescribe. No hay backtest posible del modelo de pricing, solo un analisis
-- de concordancia, y el nombre de la columna lo deja explicito.
-- owner_type, ggcc, dormitorios, banos y estudio SI se pueden usar: son
-- atributos estructurales, no salidas del modelo.
-- ---------------------------------------------------------------------------
ml AS (
    SELECT property_id, precio_recomendado_ml, precio_recomendado_actual,
           uf_m2, ggcc, owner_type, dormitorios, banos, estudio, pricing_date
    FROM (
        SELECT
            property_id, precio_recomendado_ml, precio_recomendado_actual,
            uf_m2, ggcc, owner_type, dormitorios,
            `baños` AS banos,       -- aliasado a ASCII para que el CSV y pandas
            estudio,                -- no dependan de la codificacion del cliente
            pricing_date,
            ROW_NUMBER() OVER (PARTITION BY property_id
                               ORDER BY pricing_date DESC, updated_at DESC,
                                        created_at DESC) AS rn
        FROM bi_assetplan.aa_pmPricingExplainabilityPredictions
    ) t
    WHERE rn = 1
),
-- ---------------------------------------------------------------------------
-- uni · Universo + fechas del evento. Unica referencia a `prop`.
-- ---------------------------------------------------------------------------
uni AS (
    SELECT
        p.*,
        l.fecha_LPA,
        k.fecha_check_in,
        rs.fecha_primera_reserva,
        rs.fecha_ultima_reserva_pre_contrato,
        rs.n_reservas_pre_contrato,
        rs.reservas_90d,
        rs.d0_7_reservas,
        c.renter_id, c.inicio_contrato, c.monto_arriendo, c.heredado,
        -- La base usa la fecha cero como "no desactivada", que no es NULL y por
        -- lo tanto pasa las comparaciones de fecha en silencio.
        CASE WHEN p.fecha_desactivacion > '0000-00-00'
             THEN p.fecha_desactivacion END                    AS fecha_baja,
        -- EVENTO QUE TERMINA LA VACANCIA. El contrato manda; el churn solo cuenta
        -- cuando no hubo contrato. Si no hay ninguno queda NULL y la observacion
        -- es censurada por la derecha.
        --
        -- EL CIERRE ES LA RESERVA, NO EL CONTRATO.
        -- Para una unidad que se arrendo, el momento en que deja el mercado es
        -- la primera reserva; el contrato se tramita despues. El LEAST protege
        -- del caso en que la reserva quedara registrada despues del contrato,
        -- que es exactamente lo que nos paso con el check-in.
        -- Si no hay reserva registrada, cae al contrato y origen_event_date lo
        -- declara, para que la mezcla de definiciones sea contable.
        CASE
            WHEN c.inicio_contrato IS NOT NULL
                THEN LEAST(COALESCE(rs.fecha_primera_reserva, c.inicio_contrato),
                           c.inicio_contrato)
            WHEN p.fecha_desactivacion > '0000-00-00' THEN p.fecha_desactivacion
        END                                                    AS event_date,
        -- Que regla definio la fecha de cada fila. Sin esto no hay forma de
        -- saber que fraccion del target se mide con un criterio y cual con otro.
        CASE
            WHEN c.inicio_contrato IS NOT NULL
             AND rs.fecha_primera_reserva IS NOT NULL
             AND rs.fecha_primera_reserva < c.inicio_contrato   THEN 'reserva'
            WHEN c.inicio_contrato IS NOT NULL                  THEN 'contrato'
            WHEN p.fecha_desactivacion > '0000-00-00'           THEN 'churn'
        END                                                    AS origen_event_date
    FROM prop p
    LEFT JOIN lpa l ON l.property_id = p.property_id
    LEFT JOIN chk k ON k.property_id = p.property_id
    LEFT JOIN res rs ON rs.property_id = p.property_id
    LEFT JOIN ctr c ON c.property_id = p.property_id
),
salida AS (
    SELECT
        -- ================= IDENTIFICACION =================
        u.property_id,
        u.unit_id,
        u.owner_id,
        u.edificio                                             AS grupo_edificio,

        -- ================= EX-ANTE: ubicacion =================
        u.comuna,
        u.barrio,
        u.sector_provincia,

        -- ================= EX-ANTE: unidad =================
        u.nombre_tipologia,
        COALESCE(m.dormitorios, u.dormitorios_tip)             AS dormitorios,
        COALESCE(m.banos,       u.banos_tip)                   AS banos,
        COALESCE(m.estudio,
                 CASE WHEN u.tipologia_origen = 'estudio' THEN 1 ELSE 0 END
        )                                                      AS estudio,
        NULLIF(u.m2_utiles, 0)                                 AS m2_utiles,
        ROUND(NULLIF(u.m2_utiles, 0)
              / NULLIF(COALESCE(m.dormitorios, u.dormitorios_tip), 0), 1)
                                                               AS m2_por_dormitorio,
        u.piso,
        u.acepta_mascotas,
        u.first_time_rented,
        u.ha_sido_arrendada,
        m.owner_type,
        m.ggcc,

        -- ================= EX-ANTE: precio =================
        -- REGLA 3: correlacionadas, porque historical_pricing SI tiene el indice
        -- compuesto (property_id, created_at). Cada una es un lookup de ~15 filas.
        --
        -- precio_oferta: ultimo precio VIGENTE al salir al mercado. Es el unico
        --   ex-ante puro, el que puede entrar como feature. Cae al primer precio
        --   dentro de la ventana solo si no hay historial previo al LPA, y en ese
        --   caso flag_precio_posterior_al_lpa = 1.
        -- No se aplica la banda de negocio (150k-2,5M) aca: se trae el valor crudo
        -- y el notebook decide, para que el descarte quede contado.
        (SELECT hp.monto_depto
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = u.property_id
            AND hp.monto_depto > 1
            AND hp.created_at <= u.fecha_LPA
          ORDER BY hp.created_at DESC LIMIT 1)                 AS precio_lpa,
        (SELECT hp.monto_depto
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = u.property_id
            AND hp.monto_depto > 1
            AND hp.created_at >  u.fecha_LPA
            AND hp.created_at <  COALESCE(u.event_date,
                                          u.fecha_LPA + INTERVAL 90 DAY)
          ORDER BY hp.created_at ASC LIMIT 1)                  AS precio_post,
        (SELECT COUNT(*)
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = u.property_id
            AND hp.monto_depto > 1
            AND hp.created_at <= u.fecha_LPA)                  AS n_registros_precio_previos,

        -- ================= EX-ANTE: calendario =================
        u.fecha_LPA,
        u.created                                              AS fecha_creacion,
        DATEDIFF(u.fecha_LPA, u.created)                       AS dias_habilitacion,
        DATE_FORMAT(u.fecha_LPA, '%Y-%m')                      AS cohorte_lpa,
        MONTH(u.fecha_LPA)                                     AS mes_lpa,
        YEAR(u.fecha_LPA)                                      AS year_lpa,
        QUARTER(u.fecha_LPA)                                   AS trimestre_lpa,
        DAYOFWEEK(u.fecha_LPA)                                 AS dow_lpa,

        -- ================= LANDMARK d0-7 =================
        -- Usable ex-ante para predecir los dias 8 en adelante, pero SOLO donde
        -- sobrevive_d7 = 1: en una unidad que se arrendo el dia 3 la ventana esta
        -- truncada por el evento y un conteo bajo significa poco tiempo, no poca
        -- demanda.
        COALESCE(vi.visitas_sem_1, 0)                          AS d0_7_visitas,
        COALESCE(ld.d0_7_leads,    0)                          AS d0_7_leads,
        COALESCE(u.d0_7_reservas, 0)                           AS d0_7_reservas,
        CASE
            WHEN u.event_date IS NULL
              OR u.event_date >= u.fecha_LPA + INTERVAL 7 DAY
            THEN 1 ELSE 0
        END                                                    AS sobrevive_d7,

        -- ================= TARGET: duracion =================
        DATEDIFF(u.event_date, u.fecha_LPA)                    AS no_modelo_days_to_event,
        DATEDIFF(COALESCE(u.event_date, CURDATE()), u.fecha_LPA)
                                                               AS no_modelo_dias_observados,
        CASE WHEN u.event_date IS NULL THEN 1 ELSE 0 END       AS no_modelo_censurada,
        CASE
            WHEN u.inicio_contrato IS NOT NULL THEN 'arriendo'
            WHEN u.fecha_baja      IS NOT NULL THEN 'churn'
            ELSE 'sin evento'
        END                                                    AS no_modelo_tipo_evento,
        CASE
            WHEN u.inicio_contrato IS NULL AND u.fecha_baja IS NOT NULL
            THEN 1 ELSE 0
        END                                                    AS no_modelo_churn,
        -- ---- HITOS POSTERIORES AL LPA, EN EL ORDEN REAL ----------------------
        -- MEDIDO, no supuesto: sobre 2.235 unidades arrendadas y analizables, el
        -- 100% tiene un movimiento a "Esperando Check-In" posterior al LPA, y en
        -- el 95% ese movimiento es POSTERIOR a la creacion del contrato. O sea
        -- que el estado no es un paso previo al contrato: es la espera del
        -- check-in fisico del arrendatario, que ocurre despues de firmar.
        --
        -- Consecuencia: created_at del contrato NO viene inflado por el check-in.
        -- Es el hito mas temprano de los dos, y sigue siendo el default del
        -- target. Lo que hay antes del contrato es la RESERVA.
        u.fecha_check_in                                       AS no_modelo_fecha_check_in,
        DATEDIFF(u.fecha_check_in, u.fecha_LPA)                AS no_modelo_days_to_check_in,
        -- Dias entre la creacion del contrato y la entrada a "Esperando
        -- Check-In". Positivo en el caso normal. Es tiempo de coordinacion de la
        -- entrega, no tiempo de mercado.
        DATEDIFF(u.fecha_check_in, u.inicio_contrato)          AS no_modelo_dias_contrato_a_check_in,
        -- El 5% con el orden invertido. Puede ser un ciclo de arriendo anterior
        -- o desincronizacion entre el registro de estados y el de contratos.
        -- Excluirlas antes de interpretar cualquier resta entre estas fechas.
        CASE
            WHEN u.fecha_check_in IS NOT NULL
             AND u.inicio_contrato IS NOT NULL
             AND u.fecha_check_in < u.inicio_contrato
            THEN 1 ELSE 0
        END                                                    AS flag_check_in_previo_al_contrato,
        -- ---- RESERVA: el candidato a cierre comercial ANTERIOR al contrato ---
        -- Primera reserva posterior al LPA, sin tope de 90 dias. Si la reserva
        -- precede al contrato de forma consistente, days_to_reserva es la medida
        -- de velocidad de mercado limpia y days_to_event trae adosado el tiempo
        -- de tramitacion. El notebook mide el orden antes de concluirlo.
        u.fecha_primera_reserva                                AS no_modelo_fecha_primera_reserva,
        DATEDIFF(u.fecha_primera_reserva, u.fecha_LPA)         AS no_modelo_days_to_reserva,
        DATEDIFF(u.inicio_contrato, u.fecha_primera_reserva)   AS no_modelo_dias_reserva_a_contrato,
        -- Cuando n_reservas_pre_contrato > 1 hubo reservas caidas y la PRIMERA
        -- no es el cierre: la unidad volvio al mercado. Para esas filas la buena
        -- es la ultima, y cambiar de criterio es reemplazar fecha_primera_reserva
        -- por fecha_ultima_reserva_pre_contrato en el CASE de event_date.
        u.fecha_ultima_reserva_pre_contrato                    AS no_modelo_fecha_ultima_reserva_pre_contrato,
        COALESCE(u.n_reservas_pre_contrato, 0)                 AS no_modelo_n_reservas_pre_contrato,
        -- La medida vieja, para poder cuantificar cuanto cambio el target.
        DATEDIFF(u.inicio_contrato, u.fecha_LPA)               AS no_modelo_days_to_contrato,
        u.origen_event_date                                    AS no_modelo_origen_event_date,
        u.event_date                                           AS no_modelo_event_date,
        u.inicio_contrato                                      AS no_modelo_inicio_contrato,
        u.fecha_baja                                           AS no_modelo_fecha_baja,
        u.monto_arriendo                                       AS no_modelo_monto_arriendo,
        u.renter_id                                            AS no_modelo_renter_id,
        u.actual_activa                                        AS no_modelo_actual_activa,
        CASE
            WHEN u.inicio_contrato IS NOT NULL AND u.fecha_baja IS NOT NULL
            THEN DATEDIFF(u.fecha_baja, u.inicio_contrato)
        END                                                    AS no_modelo_dias_contrato_a_baja,

        -- ================= DEMANDA (ventana fija de 90 dias) =================
        COALESCE(vi.visitas_sem_1,        0)                   AS no_modelo_visitas_sem_1,
        COALESCE(vi.visitas_sem_2,        0)                   AS no_modelo_visitas_sem_2,
        COALESCE(vi.visitas_sem_3,        0)                   AS no_modelo_visitas_sem_3,
        COALESCE(vi.visitas_sem_4,        0)                   AS no_modelo_visitas_sem_4,
        COALESCE(vi.visitas_sem5_a_90,    0)                   AS no_modelo_visitas_sem5_a_90,
        COALESCE(vi.visitas_90d,          0)                   AS no_modelo_visitas_90d,
        COALESCE(vi.dias_con_observacion, 0)                   AS no_modelo_dias_con_observacion,
        vi.first_visit_obs                                     AS no_modelo_first_visit_obs,
        vi.last_visit_obs                                      AS no_modelo_last_visit_obs,
        COALESCE(ld.leads_90d,    0)                           AS no_modelo_leads_90d,
        COALESCE(u.reservas_90d, 0)                            AS no_modelo_reservas_90d,
        -- Distingue "no tiene ninguna fila en la tabla de metricas" de "tiene
        -- filas y suman cero visitas". No son lo mismo.
        CASE WHEN vi.property_id IS NULL THEN 1 ELSE 0 END     AS flag_sin_datos_visitas,

        -- ================= PRECIO POST-LPA (descriptivo) =================
        (SELECT hp.monto_depto
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = u.property_id
            AND hp.monto_depto > 1
            AND hp.created_at <  COALESCE(u.event_date,
                                          u.fecha_LPA + INTERVAL 90 DAY)
          ORDER BY hp.created_at DESC LIMIT 1)                 AS no_modelo_precio_cierre,
        -- Sobre el precio REDONDEADO a 5.000: el reajuste UF movia el monto todos
        -- los meses y se contaba como decision de pricing. El check dio 5,2
        -- cambios por mes con 1,65% de dispersion, o sea ruido.
        (SELECT COUNT(DISTINCT ROUND(hp.monto_depto / 5000) * 5000)
           FROM assetplan_rentas.historical_pricing hp
          WHERE hp.property_id = u.property_id
            AND hp.monto_depto > 1
            AND hp.created_at >= u.fecha_LPA
            AND hp.created_at <  COALESCE(u.event_date,
                                          u.fecha_LPA + INTERVAL 90 DAY))
                                                               AS no_modelo_n_precios_ventana,

        -- ================= REFERENCIA ML (ex-post) =================
        m.precio_recomendado_ml                                AS precio_ml_expost,
        m.precio_recomendado_actual                            AS precio_ml_actual,
        m.pricing_date                                         AS ml_pricing_date,
        m.uf_m2,
        CASE WHEN m.pricing_date <= u.fecha_LPA THEN 1 ELSE 0 END
                                                               AS flag_ml_es_ex_ante,

        -- ================= DIAGNOSTICO DE CALIDAD =================
        u.heredado,
        u.tipologia_origen,
        CASE WHEN m.dormitorios IS NOT NULL THEN 'pricing'
             WHEN u.dormitorios_tip IS NOT NULL THEN 'tipologia'
             ELSE 'sin dato' END                               AS origen_dormitorios,
        CASE WHEN m.banos IS NOT NULL THEN 'pricing'
             WHEN u.banos_tip IS NOT NULL THEN 'tipologia'
             ELSE 'sin dato' END                               AS origen_banos,
        CASE
            -- MEDIDO el 2026-08-28: las 704 discrepancias del universo son TODAS
            -- el mismo caso, y no es un problema de datos sino de convencion.
            -- nombre_tipologia = 'Estudio', la tabla de pricing dice
            -- dormitorios = 1 y el parseo de aca dice 0 — pero estudio = 1 en
            -- las dos fuentes, o sea que coinciden en lo que la unidad ES.
            -- Sin esta primera rama el flag se dispara en el 9,2% del universo
            -- por una diferencia de criterio y deja de servir como senal de QA.
            -- Como COALESCE prefiere pricing, los estudios quedan con
            -- dormitorios = 1, que es la convencion de esa tabla.
            WHEN COALESCE(m.estudio, 0) = 1
             AND u.tipologia_origen = 'estudio'                 THEN 0
            WHEN m.dormitorios IS NOT NULL AND u.dormitorios_tip IS NOT NULL
             AND m.dormitorios <> u.dormitorios_tip THEN 1
            WHEN m.banos IS NOT NULL AND u.banos_tip IS NOT NULL
             AND m.banos <> u.banos_tip THEN 1
            WHEN m.estudio IS NOT NULL
             AND (m.estudio <> 0) <> (u.tipologia_origen = 'estudio') THEN 1
            ELSE 0
        END                                                    AS flag_discrepancia_tipologia,
        CASE
            WHEN u.event_date IS NOT NULL AND u.event_date < u.fecha_LPA
            THEN 1 ELSE 0
        END                                                    AS flag_evento_previo_lpa
    FROM uni u
    LEFT JOIN vis vi ON vi.property_id = u.property_id
    LEFT JOIN lds ld ON ld.property_id = u.property_id
    LEFT JOIN ml  m  ON m.property_id  = u.property_id
),
derivadas AS (
    -- Capa intermedia. Existe por una razon concreta: MySQL no deja reusar el
    -- alias de un SELECT en otra expresion del MISMO SELECT. Sin esta capa hay
    -- que repetir la formula del log-ratio tres veces (en log_ratio_ml, en el
    -- COUNT de la ventana y en el AVG), y una formula copiada tres veces es una
    -- formula que se va a desincronizar.
    SELECT
        s.*,
        -- precio_oferta: el precio con el que la unidad sale al mercado. Cae al
        -- primer precio dentro de la ventana solo si no hay historial previo al
        -- LPA, y en ese caso el flag lo declara.
        COALESCE(s.precio_lpa, s.precio_post)                  AS precio_oferta,
        CASE
            WHEN s.precio_lpa IS NULL AND s.precio_post IS NOT NULL
            THEN 1 ELSE 0
        END                                                    AS flag_precio_posterior_al_lpa,
        ROUND(COALESCE(s.precio_lpa, s.precio_post)
              / NULLIF(s.m2_utiles, 0), 0)                     AS precio_m2,
        ROUND(1 - s.no_modelo_precio_cierre
                  / NULLIF(COALESCE(s.precio_lpa, s.precio_post), 0), 4)
                                                               AS no_modelo_pct_bajada,
        ROUND(s.no_modelo_monto_arriendo
              / NULLIF(COALESCE(s.precio_lpa, s.precio_post), 0), 4)
                                                               AS no_modelo_ratio_cierre_vs_oferta,
        CASE
            WHEN s.no_modelo_n_precios_ventana = 0 THEN NULL
            WHEN s.no_modelo_n_precios_ventana = 1 THEN 1
            ELSE 0
        END                                                    AS no_modelo_precio_plano,
        ROUND(COALESCE(s.precio_lpa, s.precio_post)
              / NULLIF(GREATEST(s.precio_ml_expost, 0), 0), 4) AS ratio_ml,
        -- LN blindado: GREATEST manda los <= 0 a 0 y NULLIF los pasa a NULL, asi
        -- el argumento es > 0 o NULL, nunca 0 ni negativo.
        ROUND(LN(NULLIF(GREATEST(
                  COALESCE(s.precio_lpa, s.precio_post)
                  / NULLIF(GREATEST(s.precio_ml_expost, 0), 0)
              , 0), 0)), 4)                                    AS log_ratio_ml,
        -- Una sola columna que explica por que una fila NO es analizable.
        -- Alimenta el paso 0 del notebook. El orden de los WHEN es la prioridad.
        CASE
            WHEN s.fecha_LPA IS NULL                        THEN 'sin fecha LPA'
            WHEN s.heredado = 1                             THEN 'contrato heredado'
            WHEN s.no_modelo_event_date IS NOT NULL
             AND s.no_modelo_event_date <= s.fecha_LPA      THEN 'ventana invalida'
            WHEN COALESCE(s.precio_lpa, s.precio_post) IS NULL
                                                            THEN 'sin historical_pricing'
            ELSE 'analizable'
        END                                                    AS motivo_exclusion
    FROM salida s
)
SELECT
    d.*,
    -- Gap contra el ML centrado en su celda comuna x tipologia x mes de LPA.
    -- El centrado absorbe dos cosas a la vez: la deriva de mercado entre
    -- fecha_LPA y la fecha (ex-post) de la prediccion, y el confounding de
    -- segmento que hacia ilegible el scatter de precio contra dias.
    -- Descartar celdas con n_segmento chico antes de interpretar.
    --
    -- CORREGIDO 2026-08-31. La version anterior promediaba TODAS las filas de la
    -- celda, incluidas las que despues no entran a la muestra de trabajo. Medido
    -- sobre el resultado real: 45 filas contaminantes, 24 de ellas marcadas
    -- 'analizable' y excluidas solo por la banda de precio, con log_ratio_ml de
    -- hasta -7,03 (precio de oferta ~1/1100 de la recomendacion: error de
    -- captura, no una unidad barata; media del grupo -4,17, sd 3,63).
    --
    -- Con celdas de mediana 10 filas, cada intrusa corria la media de sus nueve
    -- vecinas ~0,4 y les inyectaba esa desviacion espuria. Efecto medido sobre
    -- la muestra de trabajo (3.834 filas):
    --     sd(log_ratio_ml)        crudo               0,1073
    --     sd(log_ratio_centrado)  version anterior    0,1705   <- SUBIA
    --     sd(log_ratio_centrado)  esta version        0,0871
    --
    -- EL CHECK: centrar dentro de un grupo solo puede REDUCIR la suma de
    -- cuadrados, porque la media del grupo es el valor que la minimiza. Si la sd
    -- del centrado sube, la media se calculo sobre otra poblacion. No hay otra
    -- explicacion posible, y por eso el notebook lo verifica con un assert.
    --
    -- El CASE de elegibilidad NO filtra la salida: las filas excluidas siguen
    -- viniendo con su motivo_exclusion, solo dejan de pesar en la media de sus
    -- vecinas. AVG y COUNT ignoran NULL, asi que no hace falta ningun WHERE ni
    -- una pasada extra: mismo plan, mismo costo. Si una celda quedara sin
    -- ninguna fila elegible, AVG devuelve NULL y log_ratio_centrado sale NULL,
    -- que es preferible a un numero equivocado.
    --
    -- La particion NO se toco: con mediana de 10 filas por celda,
    -- comuna x tipologia x cohorte esta bien dimensionada y absorbe mas
    -- confounding que cualquier alternativa mas gruesa.
    COUNT(CASE WHEN d.motivo_exclusion = 'analizable'
                AND d.precio_oferta BETWEEN 150000 AND 2500000
                AND ABS(d.log_ratio_ml) <= 1.0
               THEN d.log_ratio_ml END) OVER (
        PARTITION BY d.comuna, d.nombre_tipologia, d.cohorte_lpa
    )                                                          AS n_segmento,
    ROUND(d.log_ratio_ml
          - AVG(CASE WHEN d.motivo_exclusion = 'analizable'
                      AND d.precio_oferta BETWEEN 150000 AND 2500000
                      AND ABS(d.log_ratio_ml) <= 1.0
                     THEN d.log_ratio_ml END) OVER (
        PARTITION BY d.comuna, d.nombre_tipologia, d.cohorte_lpa
    ), 4)                                                      AS log_ratio_centrado
FROM derivadas d
ORDER BY d.fecha_LPA, d.property_id;

-- ============================================================================
-- CHECKS sobre el resultado. Correr ANTES de interpretar nada.
-- El notebook los hace todos en los pasos 0 y 1; esta lista es el recordatorio
-- para cuando se corra la query suelta en el cliente SQL.
-- ============================================================================
-- 1) Grano. Deben ser iguales.
--    SELECT COUNT(*) filas, COUNT(DISTINCT property_id) properties FROM q;
--
-- 2) Peaje de exclusiones. Si un motivo pesa mucho Y tiene otra tasa de churn,
--    filtrarlo sesga todo lo que venga despues.
--    SELECT motivo_exclusion, COUNT(*), AVG(no_modelo_churn),
--           AVG(no_modelo_censurada) FROM q GROUP BY 1 ORDER BY 2 DESC;
--
-- 3) Consistencia de la censura. Debe cumplirse siempre:
--    tipo_evento = 'sin evento' <=> censurada = 1 <=> days_to_event IS NULL
--
-- 4) EL SUPUESTO DE LA VENTANA FIJA. Si esto es alto, la ventana de 90 dias esta
--    contando actividad posterior al evento y hay que volver a recortarla:
--    SELECT AVG(no_modelo_last_visit_obs > no_modelo_event_date) FROM q
--     WHERE no_modelo_event_date IS NOT NULL
--       AND no_modelo_last_visit_obs IS NOT NULL;
--
-- 4b) EL ORDEN DE LOS HITOS. Verificar antes de elegir el target:
--    SELECT
--      AVG(no_modelo_fecha_primera_reserva < no_modelo_inicio_contrato) AS reserva_antes,
--      AVG(no_modelo_fecha_check_in       > no_modelo_inicio_contrato) AS checkin_despues
--    FROM q WHERE no_modelo_tipo_evento = 'arriendo';
--    Medido el 2026-08: checkin_despues = 95%. La reserva esta por medirse.
--
-- 4c) EL ESTADO DE CHECK-IN. Si la cobertura es baja, el nombre del estado no
--    esta matcheando y hay que corregir el LIKE del CTE `mov`:
--    SELECT AVG(no_modelo_fecha_check_in IS NOT NULL) FROM q
--     WHERE no_modelo_tipo_evento = 'arriendo';
--    Y la magnitud de la correccion:
--    SELECT AVG(no_modelo_dias_en_check_in), MEDIAN... FROM q
--     WHERE flag_check_in_posterior_al_contrato = 0;
--
-- 5) Cobertura ex-ante del ML. Si flag_ml_es_ex_ante = 1 es raro, la tabla de
--    pricing es un snapshot que se sobreescribe: no hay backtest, solo
--    concordancia. Presentarlo asi, no como desempeno del modelo.
--
-- 6) Dispersion del gap. Si sd(log_ratio_ml) < 0,05 el ML aprendio la politica de
--    precios de la casa, no el mercado: no hay varianza que correlacionar y el
--    problema esta en el target de entrenamiento de ese modelo.
--
-- 7) Duraciones negativas: SUM(flag_evento_previo_lpa) deberia ser bajo.
-- 8) Fuentes de tipologia: SUM(flag_discrepancia_tipologia) deberia ser 0 una
--    vez excluida la convencion del estudio (ver el CASE). Antes de esa
--    exclusion daba 704 sobre 7.683, todas por lo mismo.
-- 9) Comparabilidad de precios: confirmar con el equipo de pricing que
--    historical_pricing.monto_depto y precio_recomendado_ml son ambos NETOS de
--    gastos comunes. La tabla de pricing trae ggcc por separado, lo que lo
--    sugiere, pero hay que verificarlo antes de comparar niveles.
--
-- Si el tiempo se dispara otra vez, diagnostico_rendimiento.sql tiene las
-- consultas sueltas para localizar el bloque sin adivinar.
-- ============================================================================
