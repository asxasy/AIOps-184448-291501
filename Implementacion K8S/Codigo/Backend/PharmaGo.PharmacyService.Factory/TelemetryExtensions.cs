using Instrumentation;
using Microsoft.Extensions.DependencyInjection;
using OpenTelemetry.Exporter;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

namespace PharmaGo.PharmacyService.Factory
{
    public static class OpenTelemetryExtensions
    {
        /// <summary>
        /// Telemetría del servicio con OpenTelemetry: métricas y trazas por OTLP al collector
        /// (que las reenvía a Prometheus y a Jaeger) y trace_id en el scope de los logs.
        /// Se mantiene el nombre del método para no tocar Program.cs.
        /// </summary>
        public static IServiceCollection AddPharmaGoOpenTelemetryMetrics(this IServiceCollection services, string serviceName = "PharmaGo.PharmacyService")
        {
            var otlpEndpoint = TracingExtensions.OtlpEndpoint;

            services.AddTraceContextToLogs();

            services.AddOpenTelemetry()
                    // service.instance.id = nombre del pod, para distinguir réplicas en Prometheus y Jaeger.
                    .ConfigureResource(resource => resource.AddService(serviceName, serviceInstanceId: Environment.MachineName))
                    .WithMetrics(metricsBuilder => { metricsBuilder
                    .AddAspNetCoreInstrumentation()
                    .AddHttpClientInstrumentation()
                    .AddMeter("PharmaGo.CustomMetrics")
                    .AddPrometheusExporter()
                    .AddOtlpExporter(options =>
                        {
                            options.Endpoint = otlpEndpoint;
                            options.Protocol = OtlpExportProtocol.Grpc;
                        });
                    })
                    .WithTracing(tracingBuilder => { tracingBuilder
                    // Span por request entrante; el contexto llega en el header traceparent (W3C) que inyecta el Gateway.
                    .AddAspNetCoreInstrumentation(options =>
                        {
                            options.Filter = TracingExtensions.ShouldTrace;
                            options.RecordException = true;
                        })
                    // Span por llamada saliente entre servicios; propaga traceparent al destino.
                    .AddHttpClientInstrumentation(options => options.RecordException = true)
                    // Span por comando SQL que ejecuta EF Core (Microsoft.Data.SqlClient).
                    .AddSqlClientInstrumentation(options =>
                        {
                            options.SetDbStatementForText = true;
                            options.RecordException = true;
                        })
                    .AddOtlpExporter(options =>
                        {
                            options.Endpoint = otlpEndpoint;
                            options.Protocol = OtlpExportProtocol.Grpc;
                        });
                    });

            return services;
        }
    }
}
