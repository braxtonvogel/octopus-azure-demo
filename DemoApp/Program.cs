using DemoApp.Data;
using Microsoft.EntityFrameworkCore;
using Octopus.OpenFeature.Provider;
using OpenFeature;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
builder.Services.AddRazorPages();

// Octopus feature flags (via OpenFeature). The deploy script (octopus/deploy-step.ps1) sets the env var
// Octopus__FeatureFlags__ClientIdentifier from Octopus's built-in client identifier variable (that variable's
// name is not yet confirmed in a real deployment). The identifier tells Octopus this app's project, environment
// and tenant. With no identifier (local dev) no provider is registered, so every flag evaluates to its default (off).
var flagClientId = builder.Configuration["Octopus:FeatureFlags:ClientIdentifier"];
if (!string.IsNullOrWhiteSpace(flagClientId))
{
    // Flags are optional: if the provider can't start (or takes over 5 s, which could trip the Container App
    // startup probe), carry on and let every flag fall back to its default instead of crash-looping the app.
    try
    {
        await Api.Instance.SetProviderAsync(
            new OctopusFeatureProvider(new OctopusFeatureConfiguration(flagClientId, new ProductMetadata("notes-app"))))
            .WaitAsync(TimeSpan.FromSeconds(5));
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"Warning: Octopus feature flag provider didn't start ({ex.GetType().Name}); flags will use defaults.");
    }
}
// Register under the interface: the pages ask for IFeatureClient (an untyped AddSingleton registers the concrete type).
builder.Services.AddSingleton<IFeatureClient>(_ => Api.Instance.GetClient());

builder.Services.AddDbContext<AppDbContext>(o =>
    o.UseSqlServer(builder.Configuration.GetConnectionString("Default"),
        sql => sql.EnableRetryOnFailure(
            maxRetryCount: 5,
            maxRetryDelay: TimeSpan.FromSeconds(10),
            errorNumbersToAdd: null)));


var app = builder.Build();

using (var scope = app.Services.CreateScope())
{
    scope.ServiceProvider.GetRequiredService<AppDbContext>().Database.Migrate();
}

// Configure the HTTP request pipeline.
if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    // The default HSTS value is 30 days. You may want to change this for production scenarios, see https://aka.ms/aspnetcore-hsts.
    app.UseHsts();
}

app.UseHttpsRedirection();

app.UseRouting();

app.UseAuthorization();

app.MapStaticAssets();
app.MapRazorPages()
   .WithStaticAssets();

app.Run();
