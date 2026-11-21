using System.ComponentModel.DataAnnotations;
using DemoApp.Data;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.EntityFrameworkCore;
using OpenFeature;

namespace DemoApp.Pages;

public class IndexModel(AppDbContext db, IFeatureClient flags) : PageModel
{
    public List<Note> Notes { get; set; } = [];
    // Octopus feature flag "note-character-counter": shows "n / 500" under the note box. Default off.
    public bool ShowCharacterCounter { get; set; }
    [BindProperty]
    [StringLength(500)]
    public string NewText { get; set; } = "";

    public async Task OnGetAsync()
    {
        ShowCharacterCounter = await flags.GetBooleanValueAsync("note-character-counter", false);
        Notes = await db.Notes.OrderByDescending(n => n.CreatedUtc).ToListAsync();
    }

    public async Task<IActionResult> OnPostAsync()
    {
        if (!ModelState.IsValid)
        {
            ShowCharacterCounter = await flags.GetBooleanValueAsync("note-character-counter", false);
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