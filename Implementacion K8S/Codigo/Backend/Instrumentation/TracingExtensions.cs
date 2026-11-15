using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Instrumentation;

/// <summary>
/// Piezas comunes de trazas (OpenTelemetry) para el Gateway y los microservicios.
/// </summary>
public static class TracingExtensions
{
    /// <summary>Endpoint OTLP del collector; se puede sobrescribir con OTEL_EXPORTER_OTLP_ENDPOINT.</summary>
    public static Uri OtlpEndpoint =>
        new(Environment.GetEnvironmentVariable("OTEL_EXPORTER_OTLP_ENDPOINT") ?? "http://otlp-collector:4317");

    /// <summary>Cada cuánto se empujan las métricas por OTLP (default del SDK: 60 s, demasiado lento para alertar).</summary>
    public const int MetricExportIntervalMs = 10000;

    /// <summary>
    /// Requests de infraestructura que no se trazan: probes de Kubernetes (/health) y scrapes de Prometheus (/metrics).
    /// Llegan cada 5-10 s y llenarían Jaeger de trazas sin valor.
    /// </summary>
    public static bool ShouldTrace(HttpContext context)
    {
        var path = context.Request.Path;
        return !path.StartsWithSegments("/health") && !path.StartsWithSegments("/metrics");
    }

    /// <summary>
    /// Agrega TraceId, SpanId y ParentId de la Activity actual al scope de cada log.
    /// Con el formatter JSON e IncludeScopes, quedan como Scopes.TraceId en Elasticsearch,
    /// el mismo trace_id que se ve en Jaeger.
    /// </summary>
    public static IServiceCollection AddTraceContextToLogs(this IServiceCollection services)
    {
        services.Configure<LoggerFactoryOptions>(options =>
            options.ActivityTrackingOptions = ActivityTrackingOptions.TraceId
                                              | ActivityTrackingOptions.SpanId
                                              | ActivityTrackingOptions.ParentId);
        return services;
    }
}
