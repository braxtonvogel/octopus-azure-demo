using System.ComponentModel.DataAnnotations;
using DemoApp.Data;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.EntityFrameworkCore;

namespace DemoApp.Pages;

public class IndexModel(AppDbContext db) : PageModel
{
    public List<Note> Notes { get; set; } = [];
    [BindProperty]
    [StringLength(500)]
    public string NewText { get; set; } = "";

    public async Task OnGetAsync() =>
        Notes = await db.Notes.OrderByDescending(n => n.CreatedUtc).ToListAsync();

    public async Task<IActionResult> OnPostAsync()
    {
        if (!ModelState.IsValid)
        {
            Notes = await db.Notes.OrderByDescending(n => n.CreatedUtc).ToListAsync();
            return Page();
        }

        if (!string.IsNullOrWhiteSpace(NewText))
        {
            db.Notes.Add(new Note { Text = NewText.Trim() });
            await db.SaveChangesAsync();
        }
        return RedirectToPage();
    }
}