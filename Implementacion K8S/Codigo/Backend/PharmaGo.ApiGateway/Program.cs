using System.Diagnostics.CodeAnalysis;
using OpenTelemetry.Exporter;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using AspNetCoreRateLimit;
using PharmaGo.ApiGateway.Middleware;
using Instrumentation;
using InstrumentationInterface;
using Yarp.ReverseProxy.Health;
using Yarp.ReverseProxy.Transforms;

var builder = WebApplication.CreateBuilder(args);

// TraceId/SpanId de la request en el scope de cada log (Scopes.TraceId en Kibana).
builder.Services.AddTraceContextToLogs();

builder.Services.AddMemoryCache();

var rateLimitMode = builder.Configuration["RateLimiting:Mode"] ?? "IP";

if (rateLimitMode.Equals("IP", StringComparison.OrdinalIgnoreCase))
{
    // Rate limiting por IP (útil para endpoints públicos)
    builder.Services.Configure<IpRateLimitOptions>(builder.Configuration.GetSection("IpRateLimiting"));
    builder.Services.Configure<IpRateLimitPolicies>(builder.Configuration.GetSection("IpRateLimitPolicies"));
    builder.Services.AddInMemoryRateLimiting();
    builder.Services.AddSingleton<IRateLimitConfiguration, RateLimitConfiguration>();
}

builder.Services.AddReverseProxy()
    .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"))
    .AddTransforms(transformBuilder =>
    {
        transformBuilder.AddRequestTransform(context =>
        {
            if (context.HttpContext.Items.TryGetValue(CorrelationIdMiddlewareExtensions.HttpContextItemKey, out var value)
                && value is string correlationId
                && !string.IsNullOrEmpty(correlationId))
            {
                context.ProxyRequest.Headers.Remove("X-Correlation-ID");
                context.ProxyRequest.Headers.TryAddWithoutValidation("X-Correlation-ID", correlationId);
            }
            return default;
        });
    });

// Circuit breaker (health check pasivo de YARP): ventana de detección y tasa de fallas desde appsettings
// (sección ReverseProxyHealth). Sin esto YARP usa su ventana por defecto y el destino queda abierto al menos 60 s.
builder.Services.Configure<TransportFailureRateHealthPolicyOptions>(
    builder.Configuration.GetSection("ReverseProxyHealth:TransportFailureRate"));

// /health propio del Gateway para sus probes de Kubernetes: lo responde el propio proceso, sin depender de los backends.
builder.Services.AddHealthChecks();

builder.Services.AddSingleton<ICustomMetrics, CustomMetrics>();

var otlpEndpoint = TracingExtensions.OtlpEndpoint;

builder.Services.AddOpenTelemetry()
    // service.instance.id = nombre del pod, para distinguir réplicas en Prometheus y Jaeger.
    .ConfigureResource(resource => resource.AddService("PharmaGo.ApiGateway", serviceInstanceId: Environment.MachineName))
    .WithMetrics(metricsBuilder => 
    {
        metricsBuilder
            .AddAspNetCoreInstrumentation()
            .AddHttpClientInstrumentation()
            .AddMeter("PharmaGo.CustomMetrics")
            .AddPrometheusExporter();
    })
    .WithTracing(tracingBuilder =>
    {
        tracingBuilder
            // Span raíz de cada request que entra al sistema.
            .AddAspNetCoreInstrumentation(options =>
            {
                options.Filter = TracingExtensions.ShouldTrace;
                options.RecordException = true;
            })
            // Span de la llamada que YARP hace al microservicio; YARP inyecta traceparent en el request saliente.
            .AddHttpClientInstrumentation(options => options.RecordException = true)
            .AddOtlpExporter(options =>
            {
                options.Endpoint = otlpEndpoint;
                options.Protocol = OtlpExportProtocol.Grpc;
            });
    });

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

builder.Services.AddCors(options =>
{
    options.AddPolicy("MyAllowedOrigins",
        policy =>
        {
            policy.SetIsOriginAllowed(_ => true)
                .AllowAnyHeader()
                .AllowAnyMethod();
        });
});

var app = builder.Build();

app.UseCors("MyAllowedOrigins");
app.UseGatewayCorrelationId();

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseMetricsMiddleware();

if (rateLimitMode.Equals("IP", StringComparison.OrdinalIgnoreCase))
{
    app.UseIpRateLimiting();
}
else if (rateLimitMode.Equals("User", StringComparison.OrdinalIgnoreCase))
{
    app.UseUserRateLimit();
}

app.UseAuthorization();

app.MapHealthChecks("/health");
app.MapReverseProxy();
app.MapPrometheusScrapingEndpoint();

app.Run();

[ExcludeFromCodeCoverage]
public partial class Program { }

