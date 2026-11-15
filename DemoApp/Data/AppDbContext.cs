using Microsoft.EntityFrameworkCore;

namespace DemoApp.Data;

public class Note
{
    public int Id { get; set; }
    public string Text { get; set; } = "";
    public DateTime CreatedUtc { get; set; } = DateTime.UtcNow;
}

public class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public DbSet<Note> Notes => Set<Note>();
}