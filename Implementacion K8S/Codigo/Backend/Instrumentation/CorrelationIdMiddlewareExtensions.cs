using System.Diagnostics;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Instrumentation;

public static class CorrelationIdMiddlewareExtensions
{
    public const string HttpContextItemKey = "YarpCorrelationId";

    /// <summary>
    /// Ensures X-Correlation-ID exists, exposes it on the response, and stores it for YARP outbound transforms.
    /// </summary>
    public static IApplicationBuilder UseGatewayCorrelationId(this IApplicationBuilder app)
    {
        return app.Use(async (context, next) =>
        {
            var header = context.Request.Headers["X-Correlation-ID"].FirstOrDefault();
            var correlationId = string.IsNullOrWhiteSpace(header)
                ? Guid.NewGuid().ToString("D")
                : header.Trim();
            context.Items[HttpContextItemKey] = correlationId;
            context.Response.Headers["X-Correlation-ID"] = correlationId;
            TagCurrentActivity(correlationId);
            // Devuelve el trace_id para buscar la traza en Jaeger y los logs en Kibana (Scopes.TraceId).
            var traceId = Activity.Current?.TraceId.ToHexString();
            if (!string.IsNullOrEmpty(traceId))
                context.Response.Headers["X-Trace-Id"] = traceId;
            await next();
        });
    }

    /// <summary>
    /// Adds correlation_id to log scopes (from X-Correlation-ID when the gateway forwarded it, else TraceIdentifier).
    /// </summary>
    public static IApplicationBuilder UseServiceCorrelationScope(this IApplicationBuilder app)
    {
        return app.Use(async (context, next) =>
        {
            var header = context.Request.Headers["X-Correlation-ID"].FirstOrDefault();
            var correlationId = string.IsNullOrWhiteSpace(header)
                ? context.TraceIdentifier
                : header.Trim();
            context.Items[HttpContextItemKey] = correlationId;
            TagCurrentActivity(correlationId);

            var loggerFactory = context.RequestServices.GetRequiredService<ILoggerFactory>();
            var log = loggerFactory.CreateLogger("Request");
            using (log.BeginScope(new Dictionary<string, object> { ["correlation_id"] = correlationId }))
                await next();
        });
    }

    /// <summary>Copia el correlation id al span HTTP actual para poder buscarlo en Jaeger (tag correlation_id).</summary>
    private static void TagCurrentActivity(string correlationId) =>
        Activity.Current?.SetTag("correlation_id", correlationId);
}
