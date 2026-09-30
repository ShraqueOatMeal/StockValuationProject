<?php

use App\Http\Controllers\ValuationDashboardController;
use App\Http\Controllers\CompanyValuationController;
use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return redirect()->route('dashboard');
})->name('home');

Route::get('/dashboard', [ValuationDashboardController::class, 'index'])->name('dashboard');
Route::get('/companies/{ticker}', [CompanyValuationController::class, 'show'])->name('companies.show');

require __DIR__.'/settings.php';
